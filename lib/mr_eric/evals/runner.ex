defmodule MrEric.Evals.Runner do
  @moduledoc """
  Executes golden eval cases through RunWorker using the fake provider.
  """

  alias MrEric.Evals.Case, as: EvalCase
  alias MrEric.Evals.Scorer
  alias MrEric.Runs
  alias MrEric.Runs.Events
  alias MrEric.Runs.Run
  alias MrEric.Runs.RunSupervisor
  alias MrEric.Runs.Trace

  @timeout_ms 5_000
  @eval_owner_id "eval-runner"

  # A RunSupervisor dedicated to evals, independent of the app's default
  # one (and its production-sized max_concurrent_runs cap). Golden cases
  # run sequentially against a single shared supervisor instance, so a
  # cap here would eventually gate a large-enough batch on however
  # promptly earlier cases' workers reap -- exactly the kind of
  # wall-clock-tuned coupling this eval harness must not have. Sized to a
  # comfortable multiple of the golden-case count (14 as of this writing)
  # so ordinary suite growth cannot approach the cap either.
  @eval_supervisor MrEric.Evals.RunSupervisor
  @eval_max_children 64

  def run_case(%EvalCase{} = eval_case, opts \\ []) do
    ensure_runtime_started()

    workspace = setup_workspace(eval_case)

    try do
      eval_case
      |> execute_case(workspace, opts)
      |> score_case(eval_case)
    after
      File.rm_rf(workspace)
    end
  end

  defp execute_case(eval_case, workspace, opts) do
    run_id = "eval-#{eval_case.name}-#{System.unique_integer([:positive])}"
    :ok = Runs.subscribe(run_id)

    try do
      maybe_schedule_cancel(eval_case, run_id)

      run_opts =
        opts
        |> Keyword.merge(
          id: run_id,
          registry: registry(),
          provider_module: MrEric.LLM.FakeProvider,
          provider: :fake,
          model: "fake-model",
          scenario: eval_case.scenario,
          fail_role: role_value(eval_case.fail_role),
          workspace_root: workspace,
          skip_history: true,
          supervisor: @eval_supervisor,
          # Spec D: nothing here is racing a concurrency cap (see
          # @eval_supervisor above) -- this is purely memory hygiene. Each
          # worker holds its whole accumulated Run (every stage's content
          # plus the trace) until it reaps, but this function reads the run
          # exactly once, synchronously, right after `collect_events/4`
          # observes the terminal event, and nothing looks at it again after
          # that. 1s comfortably clears that in-process read (sub-millisecond)
          # while not needlessly holding a finished case's memory for the
          # interactive-UI-oriented default grace (a full minute).
          terminal_run_ttl_ms: 1_000,
          max_concurrency: 1,
          max_total_runtime_ms: 1_500,
          max_tool_calls_per_run: 4,
          max_tool_calls_per_role: 2
        )
        |> add_case_opts(eval_case)

      with {:ok, %Run{id: ^run_id}} <-
             Runs.start_run(eval_case.task, @eval_owner_id, run_opts),
           {:ok, _events} <- collect_events(eval_case, run_id, [], deadline(@timeout_ms)),
           {:ok, run} <- Runs.get_run(run_id) do
        {:ok,
         %{
           status: run.status,
           final: run.final,
           # The planner prompt is the only place RAG context reaches a model,
           # and `SecretChecker.scan/1` walks `actual` by denylist -- a field
           # that is not here is a field that is never scanned.
           plan: Run.stage(run, :planner),
           trace: run.trace,
           changed_files: run.changed_files,
           drafts: [
             Run.stage(run, :local_drafter),
             Run.stage(run, :cloud_drafter)
           ],
           reviews: [
             Run.stage(run, :critic),
             Run.stage(run, :reviewer)
           ]
         }}
      else
        {:error, reason} ->
          {:error,
           %{
             status: :failed,
             final: "",
             trace:
               Trace.new(run_id, eval_case.task, :fake, "fake-model")
               |> Trace.record(:run_failed, %{error: reason})
           }}
      end
    after
      Runs.unsubscribe(run_id)
    end
  end

  defp score_case({:ok, actual}, eval_case), do: Scorer.score(eval_case, actual)
  defp score_case({:error, actual}, eval_case), do: Scorer.score(eval_case, actual)

  defp collect_events(eval_case, run_id, events, deadline_at) do
    remaining = max(deadline_at - System.monotonic_time(:millisecond), 0)

    receive do
      {event, payload} ->
        if event in Events.names() and is_map(payload) and Map.get(payload, :run_id) == run_id do
          handle_eval_event(eval_case, run_id, event, payload)

          events = events ++ [{event, payload}]

          if terminal_event?(event) do
            {:ok, events}
          else
            collect_events(eval_case, run_id, events, deadline_at)
          end
        else
          collect_events(eval_case, run_id, events, deadline_at)
        end
    after
      remaining ->
        {:error, :timeout}
    end
  end

  defp handle_eval_event(eval_case, run_id, :tool_approval_requested, payload) do
    approval_id = Map.fetch!(payload, :approval_id)

    case eval_case.approval_action do
      :approve -> Runs.approve_tool(run_id, approval_id, @eval_owner_id)
      :reject -> Runs.deny_tool(run_id, approval_id, @eval_owner_id)
      _other -> :ok
    end
  end

  defp handle_eval_event(_eval_case, _run_id, _event, _payload), do: :ok

  defp terminal_event?(event), do: event in [:run_completed, :run_failed, :run_cancelled]

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp registry do
    %{
      planner: [%{name: "planner", provider: :fake, model: "fake-planner", role: :planner}],
      drafts: [
        %{name: "local-drafter", provider: :fake, model: "fake-local", role: :local_drafter},
        %{name: "cloud-drafter", provider: :fake, model: "fake-cloud", role: :cloud_drafter}
      ],
      reviewers: [
        %{name: "critic", provider: :fake, model: "fake-critic", role: :critic},
        %{name: "reviewer", provider: :fake, model: "fake-reviewer", role: :reviewer}
      ],
      synthesizer: [
        %{name: "synthesizer", provider: :fake, model: "fake-synth", role: :synthesizer}
      ]
    }
  end

  defp add_case_opts(opts, %{scenario: "rag_context_used"}) do
    Keyword.put(opts, :rag_context, "Project context:\nphase9-rag-context")
  end

  defp add_case_opts(opts, %{scenario: "rag_failure_does_not_break_run"}) do
    Keyword.put(opts, :rag_module, MrEric.Evals.RaisingRAG)
  end

  defp add_case_opts(opts, %{scenario: "cancelled_run"}) do
    Keyword.put(opts, :delay_ms, 500)
  end

  defp add_case_opts(opts, _eval_case), do: opts

  defp maybe_schedule_cancel(%{cancel_after_ms: delay}, run_id)
       when is_integer(delay) and delay >= 0 do
    parent = self()

    Task.start(fn ->
      Process.sleep(delay)
      Runs.cancel_run(run_id, @eval_owner_id)
      send(parent, {:phase9_cancel_sent, run_id})
    end)
  end

  defp maybe_schedule_cancel(_eval_case, _run_id), do: :ok

  defp setup_workspace(eval_case) do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "mr-eric-eval-#{eval_case.name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "note.txt"), "old\n")
    seed_scenario_files(workspace, eval_case.scenario)
    System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)
    System.cmd("git", ["add", "note.txt"], cd: workspace, stderr_to_stdout: true)
    workspace
  end

  # `rag_default_index` drives the real `MrEric.RAG.Index.build/1`, so the
  # workspace has to contain both something the index must find and everything
  # Spec A says it must not. Every secret here is a fixed dummy value shaped to
  # match `SecretChecker`'s patterns.
  #
  # What this case actually proves is that the *marker* reached the planner
  # through the real index: `FakeProvider` fails the planner outright when it
  # does not, so `expected_status` is the load-bearing assertion. The secret
  # files are a guard, not an exercised assertion, and it is worth knowing why
  # rather than assuming otherwise. Each of them is excluded by several
  # independent rules -- `.env` by extension *and* by name *and* by
  # `Policy.secret_path?/1`; `server.key` by ignored extension *and* by
  # `priv/cert`; `dev.secret.exs` by `config` *and* by
  # `Policy.resolve_workspace_path/2`, which rejects any path matching
  # /secret|credential|token/ -- so removing any single rule surfaces nothing.
  # And even a secret that did reach the planner stage would not fail on
  # `:secret_leak`: `Events.normalize_event/2` runs `redact_secrets/1` over
  # every binary in a `stage_completed` payload, so `Run.stages` holds the
  # masked text long before `SecretChecker` walks `actual`.
  defp seed_scenario_files(workspace, "rag_default_index") do
    File.write!(
      Path.join(workspace, "README.md"),
      """
      MrEric notes: phase9-default-index-marker
      The planner should see this file and nothing under config or priv/cert.
      """
    )

    File.write!(
      Path.join(workspace, ".env"),
      "OPENAI_API_KEY=sk-phase9dummysecret123456789\n"
    )

    File.mkdir_p!(Path.join(workspace, "config"))

    File.write!(
      Path.join(workspace, "config/dev.secret.exs"),
      ~s(import Config\nconfig :mr_eric, secret: "sk-phase9dummysecret123456789"\n)
    )

    File.mkdir_p!(Path.join(workspace, "priv/cert"))

    File.write!(
      Path.join(workspace, "priv/cert/server.key"),
      "-----BEGIN RSA PRIVATE KEY-----\nphase9dummy\n-----END RSA PRIVATE KEY-----\n"
    )

    :ok
  end

  defp seed_scenario_files(_workspace, _scenario), do: :ok

  defp role_value(nil), do: nil
  defp role_value(role), do: role

  defp ensure_runtime_started do
    if Process.whereis(MrEric.Runs.RunSupervisor) do
      :ok
    else
      {:ok, _apps} = Application.ensure_all_started(:mr_eric)
      :ok
    end

    ensure_eval_supervisor_started()
  end

  defp ensure_eval_supervisor_started do
    case RunSupervisor.start_link(name: @eval_supervisor, max_children: @eval_max_children) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      # Anything else is a start failure, not a shape to guess at. Say which
      # supervisor and why, rather than letting a CaseClauseError surface from
      # inside the harness with the reason buried in the term.
      other ->
        raise "could not start the eval run supervisor #{inspect(@eval_supervisor)}: " <>
                inspect(other)
    end
  end
end
