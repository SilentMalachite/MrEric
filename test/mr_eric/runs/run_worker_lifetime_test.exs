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

  test "stops the worker after a completed run's grace period" do
    {_run, pid} = start_worker(@reap_opts)
    ref = Process.monitor(pid)

    send(pid, {:run_completed, %{final: "done"}})

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "stops the worker after a failed run's grace period" do
    {_run, pid} = start_worker(@reap_opts)
    ref = Process.monitor(pid)

    send(pid, {:run_failed, %{error: :boom}})

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "stops the worker after a cancelled run's grace period" do
    {_run, pid} = start_worker(@reap_opts)
    ref = Process.monitor(pid)

    assert :ok = RunWorker.cancel(pid, "lifetime-owner")

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
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

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
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
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

    assert {:ok, _run} =
             Runs.start_run(
               "third",
               "lifetime-owner",
               opts ++ [id: "run-slot-#{System.unique_integer([:positive])}"]
             )
  end
end
