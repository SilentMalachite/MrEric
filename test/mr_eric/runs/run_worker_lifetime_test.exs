defmodule MrEric.Runs.RunWorkerLifetimeTest do
  use ExUnit.Case, async: false

  alias MrEric.Runs
  alias MrEric.Runs.Run
  alias MrEric.Runs.RunSupervisor
  alias MrEric.Runs.RunWorker

  defmodule IdleOrchestrator do
    @moduledoc false
    def stream(_task, _pid, _opts), do: Process.sleep(:infinity)
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

    assert {:ok, %Run{status: :failed}} = RunWorker.get_run(pid)
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
end
