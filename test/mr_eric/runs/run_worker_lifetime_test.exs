defmodule MrEric.Runs.RunWorkerLifetimeTest do
  use ExUnit.Case, async: false

  alias MrEric.Runs
  alias MrEric.Runs.Run
  alias MrEric.Runs.RunSupervisor
  alias MrEric.Runs.Trace
  alias MrEric.Runs.RunWorker

  defmodule IdleOrchestrator do
    @moduledoc false
    def stream(_task, _pid, _opts), do: Process.sleep(:infinity)
  end

  # Stands in for a tool that never returns -- `System.cmd/3` has no timeout,
  # so an approved `shell_command` really can hang for as long as the child
  # process does. The point of the stub is that the block happens *inside the
  # executor call*, which is where the real one blocks too.
  defmodule BlockingExecutor do
    @moduledoc false
    def request_tool(_tool, _args, _reason, opts) do
      {:approval_required,
       %{
         tool: :shell_command,
         args: %{"command" => "ls"},
         approval_id: "approval-blocking-#{System.unique_integer([:positive])}",
         tool_call_id: Keyword.get(opts, :tool_call_id),
         requested_at: DateTime.utc_now(),
         expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
       }}
    end

    def execute_approved(_request, _opts), do: Process.sleep(:infinity)
  end

  # The unapproved path blocks in the same place: `Executor.request_tool/4`
  # runs read-only tools (`git_diff`, `file_read`) to completion before it
  # returns.
  defmodule BlockingRequestExecutor do
    @moduledoc false
    def request_tool(_tool, _args, _reason, _opts), do: Process.sleep(:infinity)
    def execute_approved(_request, _opts), do: Process.sleep(:infinity)
  end

  defp start_worker(opts) do
    run =
      Run.new("lifetime",
        owner_id: "lifetime-owner",
        id: "run-life-#{System.unique_integer([:positive])}"
      )

    {:ok, pid} =
      RunWorker.start_link(run: run, opts: opts, auto_start: false, name: nil)

    {run, pid}
  end

  @reap_opts [terminal_run_ttl_ms: 30, skip_history: true]

  # These are timeout margins, not timing assertions: every wait below is on a
  # timer of tens of milliseconds, so a generous budget costs nothing on the
  # happy path and buys immunity to CPU contention on a loaded machine. Under
  # 3x core oversubscription a 1_000 ms budget flaked on roughly a quarter of
  # seeds — always "the right message arrived too late", never a wrong ordering.
  @wait_ms 5_000

  # Two tests below need real work to happen *inside* the hard-deadline window
  # rather than merely waiting for it, so they trade the 30 ms window the other
  # deadline tests use for a 300 ms one.
  @wide_deadline_opts [max_total_runtime_ms: 200, hard_deadline_grace_ms: 100]

  defp start_blocked_on_approved_tool(run_id, opts) do
    run = Run.new("stuck in a tool", owner_id: "lifetime-owner", id: run_id)
    :ok = Runs.subscribe(run_id)

    {:ok, pid} =
      RunWorker.start_link(
        run: run,
        opts: [orchestrator_module: IdleOrchestrator, executor_module: BlockingExecutor] ++ opts,
        auto_start: true,
        name: nil
      )

    assert_receive {:run_started, %{run_id: ^run_id}}, @wait_ms

    send(
      pid,
      {:tool_requested, %{tool: :shell_command, input: %{"command" => "ls"}, role: :planner}}
    )

    assert_receive {:tool_approval_requested, %{run_id: ^run_id, approval_id: approval_id}},
                   @wait_ms

    assert :ok = RunWorker.approve_tool(pid, approval_id, "lifetime-owner")

    pid
  end

  defp tool_task_refs(pid), do: pid |> :sys.get_state() |> Map.fetch!(:tool_tasks) |> Map.keys()

  defp tool_task_pids(pid) do
    pid
    |> :sys.get_state()
    |> Map.fetch!(:tool_tasks)
    |> Enum.map(fn {_ref, %{task: task}} -> task.pid end)
  end

  test "stops the worker after a completed run's grace period" do
    {_run, pid} = start_worker(@reap_opts)
    ref = Process.monitor(pid)

    send(pid, {:run_completed, %{final: "done"}})

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @wait_ms
  end

  test "stops the worker after a failed run's grace period" do
    {_run, pid} = start_worker(@reap_opts)
    ref = Process.monitor(pid)

    send(pid, {:run_failed, %{error: :boom}})

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @wait_ms
  end

  test "stops the worker after a cancelled run's grace period" do
    {_run, pid} = start_worker(@reap_opts)
    ref = Process.monitor(pid)

    assert :ok = RunWorker.cancel(pid, "lifetime-owner")

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @wait_ms
  end

  test "never reaps a run that has not reached a terminal status" do
    {_run, pid} = start_worker(@reap_opts)
    ref = Process.monitor(pid)

    send(pid, {:stage_completed, %{role: :planner, content: "partial"}})

    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 300
    assert Process.alive?(pid)
  end

  test "ignores a stray :reap message when the run is not terminal" do
    {_run, pid} = start_worker(@reap_opts)
    ref = Process.monitor(pid)

    send(pid, :reap)

    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 300
    assert Process.alive?(pid)
    refute :sys.get_state(pid).reap_scheduled?
  end

  test "a spent :reap leaves the reap re-armable when the run left terminal status" do
    # Long TTL so the only :reap the worker sees during this test is the one
    # sent by hand -- the timing here is exact, not a race.
    {_run, pid} = start_worker(terminal_run_ttl_ms: 5_000, skip_history: true)
    ref = Process.monitor(pid)

    send(pid, {:run_completed, %{final: "done"}})
    assert :sys.get_state(pid).reap_scheduled?

    # A run that has gone terminal can no longer be put back to a live status
    # through the mailbox: @reviving_events are dropped once Run.terminal?/1
    # holds (see "a late stage_chunk cannot revive a completed run"). So the
    # state below -- non-terminal with the reap already scheduled -- is forced
    # rather than driven by an event. Clearing the flag stays defence in depth:
    # it is what keeps a spent :reap from short-circuiting maybe_schedule_reap/1
    # forever, and it must not rot just because its one former route is closed.
    :sys.replace_state(pid, fn state -> put_in(state.run.status, :running) end)
    state = :sys.get_state(pid)
    refute Run.terminal?(state.run)
    assert state.reap_scheduled?

    # The scheduled :reap now arrives and correctly declines to stop a running
    # worker -- but its timer is spent, so the flag has to come down with it.
    # Left set, maybe_schedule_reap/1 short-circuits forever and this worker
    # holds its supervisor slot until the hard deadline.
    send(pid, :reap)
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 300
    refute :sys.get_state(pid).reap_scheduled?

    # And the point of clearing it: the next terminal status arms a new stop.
    send(pid, {:run_completed, %{final: "done again"}})
    assert :sys.get_state(pid).reap_scheduled?
  end

  test "schedules the stop exactly once, even when late events arrive" do
    {_run, pid} = start_worker(terminal_run_ttl_ms: 5_000, skip_history: true)

    send(pid, {:run_completed, %{final: "done"}})
    send(pid, {:tool_completed, %{tool: :file_read, tool_call_id: "late", result: %{}}})

    state = :sys.get_state(pid)
    assert state.reap_scheduled?
    assert Run.terminal?(state.run)
    assert Process.alive?(pid)
  end

  test "records history before the worker exits" do
    agent_name = :"history_agent_#{System.unique_integer([:positive])}"
    start_supervised!({MrEric.Agent, name: agent_name})

    {_run, pid} =
      start_worker(terminal_run_ttl_ms: 30, agent_server: agent_name)

    ref = Process.monitor(pid)
    send(pid, {:run_completed, %{final: "recorded"}})

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @wait_ms
    assert [%{final: "recorded"}] = MrEric.Agent.history(agent_name)
  end

  test "releases the supervisor slot for the next run" do
    sup_name = :"run_sup_life_#{System.unique_integer([:positive])}"
    start_supervised!({RunSupervisor, name: sup_name, max_children: 1})

    opts = [
      orchestrator_module: IdleOrchestrator,
      supervisor: sup_name,
      skip_history: true,
      terminal_run_ttl_ms: 30
    ]

    first_id = "run-slot-#{System.unique_integer([:positive])}"
    assert {:ok, _run} = Runs.start_run("first", "lifetime-owner", opts ++ [id: first_id])

    assert {:error, :too_many_runs} =
             Runs.start_run(
               "second",
               "lifetime-owner",
               opts ++ [id: "run-slot-#{System.unique_integer([:positive])}"]
             )

    pid = RunWorker.test_pid(first_id)
    ref = Process.monitor(pid)
    assert :ok = Runs.cancel_run(first_id, "lifetime-owner")
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @wait_ms

    assert {:ok, _run} =
             Runs.start_run(
               "third",
               "lifetime-owner",
               opts ++ [id: "run-slot-#{System.unique_integer([:positive])}"]
             )
  end

  test "terminalises a run that never finishes, at the absolute deadline" do
    run_id = "run-deadline-#{System.unique_integer([:positive])}"
    run = Run.new("stuck", owner_id: "lifetime-owner", id: run_id)

    :ok = Runs.subscribe(run_id)

    {:ok, pid} =
      RunWorker.start_link(
        run: run,
        opts: [
          orchestrator_module: IdleOrchestrator,
          max_total_runtime_ms: 20,
          hard_deadline_grace_ms: 10,
          terminal_run_ttl_ms: 5_000,
          skip_history: true
        ],
        auto_start: true,
        name: nil
      )

    assert_receive {:run_failed, %{run_id: ^run_id, error: message}}, @wait_ms
    assert message =~ "maximum lifetime"

    assert {:ok, %Run{status: :failed} = failed} = RunWorker.get_run(pid)

    # Through the worker, not through Errors.classify/1 in isolation: the
    # deadline's `:run_lifetime_exceeded` reaches the trace only after
    # Events.normalize_event/2 has replaced it with a sentence, and a run
    # stopped at its deadline has to read as a timeout in the trace an eval
    # or an operator actually looks at.
    assert failed.trace.error_classification == :timeout
    assert Trace.summary(failed.trace).error_classification == :timeout
  end

  test "the deadline is inert once the run has already finished" do
    run_id = "run-deadline-ok-#{System.unique_integer([:positive])}"
    run = Run.new("quick", owner_id: "lifetime-owner", id: run_id)

    :ok = Runs.subscribe(run_id)

    {:ok, pid} =
      RunWorker.start_link(
        run: run,
        opts:
          @wide_deadline_opts ++
            [
              terminal_run_ttl_ms: 5_000,
              skip_history: true
            ],
        auto_start: false,
        name: nil
      )

    # The completion has to land before the hard deadline for this test to be
    # about inertness at all; @wide_deadline_opts gives it 300 ms to do so.
    send(pid, {:run_completed, %{final: "fast"}})
    assert_receive {:run_completed, %{run_id: ^run_id}}, @wait_ms

    # Longer than the 300 ms deadline, so the deadline provably fired and found
    # the run already terminal instead of simply not having fired yet.
    refute_receive {:run_failed, %{run_id: ^run_id}}, 600
    assert {:ok, %Run{status: :completed}} = RunWorker.get_run(pid)
  end

  test "a hard-deadline failure also releases the supervisor slot" do
    sup_name = :"run_sup_deadline_#{System.unique_integer([:positive])}"
    start_supervised!({RunSupervisor, name: sup_name, max_children: 1})

    opts = [
      orchestrator_module: IdleOrchestrator,
      supervisor: sup_name,
      skip_history: true,
      max_total_runtime_ms: 20,
      hard_deadline_grace_ms: 10,
      terminal_run_ttl_ms: 30
    ]

    first_id = "run-deadline-slot-#{System.unique_integer([:positive])}"
    assert {:ok, _run} = Runs.start_run("stuck", "lifetime-owner", opts ++ [id: first_id])

    pid = RunWorker.test_pid(first_id)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @wait_ms

    assert {:ok, _run} =
             Runs.start_run(
               "next",
               "lifetime-owner",
               opts ++ [id: "run-deadline-slot-#{System.unique_integer([:positive])}"]
             )
  end

  test "the deadline still fires when the worker is constructed with auto_start: false" do
    run_id = "run-deadline-noauto-#{System.unique_integer([:positive])}"
    run = Run.new("stuck", owner_id: "lifetime-owner", id: run_id)

    :ok = Runs.subscribe(run_id)

    {:ok, pid} =
      RunWorker.start_link(
        run: run,
        opts:
          @wide_deadline_opts ++
            [
              terminal_run_ttl_ms: 5_000,
              skip_history: true
            ],
        auto_start: false,
        name: nil
      )

    # Has to observe the run *before* the deadline fires; @wide_deadline_opts
    # gives it 300 ms rather than 30 ms to get here.
    refute Run.terminal?(elem(RunWorker.get_run(pid), 1))

    assert_receive {:run_failed, %{run_id: ^run_id, error: message}}, @wait_ms
    assert message =~ "maximum lifetime"

    assert {:ok, %Run{status: :failed}} = RunWorker.get_run(pid)
  end

  test "a hard-deadline failure suppresses a late run_completed from the killed task and never writes history" do
    agent_name = :"history_agent_deadline_#{System.unique_integer([:positive])}"
    start_supervised!({MrEric.Agent, name: agent_name})

    run_id = "run-deadline-late-#{System.unique_integer([:positive])}"
    run = Run.new("stuck", owner_id: "lifetime-owner", id: run_id)

    :ok = Runs.subscribe(run_id)

    {:ok, pid} =
      RunWorker.start_link(
        run: run,
        opts: [
          orchestrator_module: IdleOrchestrator,
          max_total_runtime_ms: 20,
          hard_deadline_grace_ms: 10,
          terminal_run_ttl_ms: 5_000,
          agent_server: agent_name
        ],
        auto_start: true,
        name: nil
      )

    assert_receive {:run_failed, %{run_id: ^run_id, error: _message}}, @wait_ms

    # Simulate the doomed orchestrator task's :run_completed landing in the
    # worker's mailbox just after :hard_deadline was already processed and
    # killed it — the exact race the :cancelled? flag exists to close off.
    send(pid, {:run_completed, %{final: "too-late"}})

    refute_receive {:run_completed, %{run_id: ^run_id}}, 300

    assert {:ok, %Run{status: :failed}} = RunWorker.get_run(pid)
    assert [] = MrEric.Agent.history(agent_name)
  end

  describe "an abnormal orchestrator-task exit" do
    # The orchestrator task's :run_completed is a plain send/2, so it reaches
    # the worker *before* the task's :DOWN. If the task then exits abnormally,
    # overwriting the run with run_failed contradicts the history entry that
    # the run_completed already wrote.
    test "leaves a run that already completed alone, and writes no second outcome" do
      agent_name = :"history_agent_down_#{System.unique_integer([:positive])}"
      start_supervised!({MrEric.Agent, name: agent_name})

      run_id = "run-down-completed-#{System.unique_integer([:positive])}"
      run = Run.new("finishes first", owner_id: "lifetime-owner", id: run_id)

      :ok = Runs.subscribe(run_id)

      {:ok, pid} =
        RunWorker.start_link(
          run: run,
          opts: [
            orchestrator_module: IdleOrchestrator,
            terminal_run_ttl_ms: 5_000,
            agent_server: agent_name
          ],
          auto_start: true,
          name: nil
        )

      assert_receive {:run_started, %{run_id: ^run_id}}, @wait_ms

      send(pid, {:run_completed, %{final: "done"}})
      assert_receive {:run_completed, %{run_id: ^run_id}}, @wait_ms

      task = :sys.get_state(pid).task
      send(pid, {:DOWN, task.ref, :process, task.pid, :boom})

      refute_receive {:run_failed, %{run_id: ^run_id}}, 300

      assert {:ok, %Run{status: :completed}} = RunWorker.get_run(pid)
      assert [%{final: "done"}] = MrEric.Agent.history(agent_name)
    end

    # stream_drafts/stream_reviews run their children under Task.async_stream
    # and each child sends to the worker directly. When the parent task dies
    # abnormally, a sibling's chunk can still be in flight — and
    # Run.do_apply_event/3 puts :stage_chunk back to :streaming unconditionally.
    test "suppresses a straggler stage_chunk from the killed task's children" do
      run_id = "run-down-late-chunk-#{System.unique_integer([:positive])}"
      run = Run.new("crashes", owner_id: "lifetime-owner", id: run_id)

      :ok = Runs.subscribe(run_id)

      {:ok, pid} =
        RunWorker.start_link(
          run: run,
          opts: [
            orchestrator_module: IdleOrchestrator,
            terminal_run_ttl_ms: 5_000,
            skip_history: true
          ],
          auto_start: true,
          name: nil
        )

      assert_receive {:run_started, %{run_id: ^run_id}}, @wait_ms

      task = :sys.get_state(pid).task
      send(pid, {:DOWN, task.ref, :process, task.pid, :boom})
      assert_receive {:run_failed, %{run_id: ^run_id}}, @wait_ms

      send(pid, {:stage_chunk, %{role: :local_drafter, chunk: "straggler"}})

      refute_receive {:stage_chunk, %{run_id: ^run_id}}, 300
      assert {:ok, %Run{status: :failed}} = RunWorker.get_run(pid)
    end
  end

  # The :cancelled? flag covers the three paths that kill the task themselves.
  # A run that finished *normally* never sets it, so a straggler from a
  # parallel stage still had a way back into Run.do_apply_event/3.
  test "a late stage_chunk cannot revive a completed run" do
    run_id = "run-late-chunk-#{System.unique_integer([:positive])}"
    run = Run.new("completes", owner_id: "lifetime-owner", id: run_id)

    :ok = Runs.subscribe(run_id)

    {:ok, pid} =
      RunWorker.start_link(
        run: run,
        opts: [terminal_run_ttl_ms: 5_000, skip_history: true],
        auto_start: false,
        name: nil
      )

    send(pid, {:run_completed, %{final: "done"}})
    assert_receive {:run_completed, %{run_id: ^run_id}}, @wait_ms

    send(pid, {:stage_chunk, %{role: :local_drafter, chunk: "straggler"}})

    refute_receive {:stage_chunk, %{run_id: ^run_id}}, 300
    assert {:ok, %Run{status: :completed}} = RunWorker.get_run(pid)
  end

  # RunWorker's @reviving_events has to name exactly the events that
  # Run.do_apply_event/3 will take back out of a terminal status. `Run` is the
  # authority and a frozen file, so this test derives that set independently
  # -- by probing every event name against Run's actual behaviour -- and
  # pins RunWorker.reviving_events/0 to it in both directions: a reviving
  # event `Run` gains that @reviving_events is missing fails here, and so
  # does one removed from @reviving_events that `Run` still revives on.
  test "the reviving-event list matches what Run actually un-terminalises" do
    completed =
      "probe"
      |> Run.new(
        owner_id: "lifetime-owner",
        id: "run-probe-#{System.unique_integer([:positive])}"
      )
      |> Run.apply_event({:run_completed, %{final: "done"}})

    reviving =
      MrEric.Runs.Events.names()
      |> Enum.reject(&Run.terminal?(Run.apply_event(completed, {&1, %{role: :planner}})))
      |> Enum.sort()

    assert reviving == Enum.sort(RunWorker.reviving_events())
  end

  # Every other deadline test above uses IdleOrchestrator, whose stream/3 sleeps
  # in a *task* -- the worker's own mailbox stays empty, so :hard_deadline is
  # always processed promptly. The tool broker is the one path that blocks the
  # worker process itself, and `System.cmd/3` has no timeout, so nothing bounds
  # how long it blocks for.
  describe "a tool that never returns" do
    test "does not stop the absolute deadline from terminalising the run" do
      run_id = "run-deadline-tool-#{System.unique_integer([:positive])}"

      start_blocked_on_approved_tool(
        run_id,
        @wide_deadline_opts ++ [terminal_run_ttl_ms: 5_000, skip_history: true]
      )

      assert_receive {:run_failed, %{run_id: ^run_id, error: message}}, @wait_ms
      assert message =~ "maximum lifetime"
    end

    test "does not stop the absolute deadline on the unapproved path either" do
      run_id = "run-deadline-request-#{System.unique_integer([:positive])}"
      run = Run.new("stuck in a tool", owner_id: "lifetime-owner", id: run_id)

      :ok = Runs.subscribe(run_id)

      {:ok, pid} =
        RunWorker.start_link(
          run: run,
          opts:
            @wide_deadline_opts ++
              [
                orchestrator_module: IdleOrchestrator,
                executor_module: BlockingRequestExecutor,
                terminal_run_ttl_ms: 5_000,
                skip_history: true
              ],
          auto_start: true,
          name: nil
        )

      assert_receive {:run_started, %{run_id: ^run_id}}, @wait_ms
      send(pid, {:tool_requested, %{tool: :git_diff, input: %{}, role: :planner}})

      assert_receive {:run_failed, %{run_id: ^run_id, error: message}}, @wait_ms
      assert message =~ "maximum lifetime"
    end

    test "leaves the worker answering calls while it runs" do
      run_id = "run-responsive-tool-#{System.unique_integer([:positive])}"

      pid =
        start_blocked_on_approved_tool(run_id,
          terminal_run_ttl_ms: 5_000,
          skip_history: true
        )

      assert {:ok, %Run{id: ^run_id}} = RunWorker.get_run(pid)
      assert :ok = RunWorker.cancel(pid, "lifetime-owner")
      assert {:ok, %Run{status: :cancelled}} = RunWorker.get_run(pid)
    end

    test "does not hold its supervisor slot past the deadline" do
      run_id = "run-slot-tool-#{System.unique_integer([:positive])}"

      pid =
        start_blocked_on_approved_tool(
          run_id,
          @wide_deadline_opts ++ [terminal_run_ttl_ms: 30, skip_history: true]
        )

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @wait_ms
    end

    # The tool task outlives nothing: a worker that terminalises while a tool is
    # still running must take the tool process down with it, or the `System.cmd`
    # child keeps running with no worker left to receive its output.
    test "is shut down when the run terminalises under it" do
      run_id = "run-tool-shutdown-#{System.unique_integer([:positive])}"

      pid =
        start_blocked_on_approved_tool(run_id,
          terminal_run_ttl_ms: 5_000,
          skip_history: true
        )

      [tool_pid] = tool_task_pids(pid)
      tool_ref = Process.monitor(tool_pid)

      assert :ok = RunWorker.cancel(pid, "lifetime-owner")

      assert_receive {:DOWN, ^tool_ref, :process, ^tool_pid, _reason}, @wait_ms
      assert tool_task_pids(pid) == []
    end

    # A tool result that lands after the deadline already failed the run must
    # not broadcast, for the same reason a straggler stage_chunk must not: the
    # run's outcome is final.
    test "cannot broadcast a result once the run is already terminal" do
      run_id = "run-late-tool-result-#{System.unique_integer([:positive])}"

      pid =
        start_blocked_on_approved_tool(
          run_id,
          @wide_deadline_opts ++ [terminal_run_ttl_ms: 5_000, skip_history: true]
        )

      # Captured while the tool is still in flight: the deadline shuts the tool
      # task down and forgets its ref, so this is the only moment it exists.
      [ref] = tool_task_refs(pid)

      assert_receive {:run_failed, %{run_id: ^run_id}}, @wait_ms

      send(pid, {ref, {:ok, %{output: "too-late"}}})

      refute_receive {:tool_completed, %{run_id: ^run_id}}, 300
      assert {:ok, %Run{status: :failed}} = RunWorker.get_run(pid)
    end
  end
end
