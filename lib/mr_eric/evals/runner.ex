defmodule MrEric.Evals.Runner do
  @moduledoc """
  Executes golden eval cases through RunWorker using the fake provider.
  """

  alias MrEric.Evals.Case, as: EvalCase
  alias MrEric.Evals.Scorer
  alias MrEric.Runs
  alias MrEric.Runs.Events
  alias MrEric.Runs.Run
  alias MrEric.Runs.Trace

  @timeout_ms 5_000
  @eval_owner_id "eval-runner"

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
    System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)
    System.cmd("git", ["add", "note.txt"], cd: workspace, stderr_to_stdout: true)
    workspace
  end

  defp role_value(nil), do: nil
  defp role_value(role), do: role

  defp ensure_runtime_started do
    if Process.whereis(MrEric.Runs.RunSupervisor) do
      :ok
    else
      {:ok, _apps} = Application.ensure_all_started(:mr_eric)
      :ok
    end
  end
end
