defmodule MrEric.RunsTest do
  use ExUnit.Case

  alias MrEric.Orchestrator
  alias MrEric.Runs
  alias MrEric.Runs.Run
  alias MrEric.Runs.RunWorker

  @registry %{
    planner: [%{name: "planner", provider: :ollama, model: "planner-model"}],
    drafts: [
      %{name: "draft-local", provider: :ollama, model: "local-model"},
      %{name: "draft-cloud", provider: :openai, model: "cloud-model", fail: true}
    ],
    reviewers: [
      %{name: "critic", provider: :ollama, model: "critic-model"},
      %{name: "reviewer", provider: :openai, model: "reviewer-model"}
    ],
    synthesizer: [%{name: "synth", provider: :ollama, model: "synth-model"}]
  }

  @opts [
    registry: @registry,
    provider_module: MrEric.LLM.FakeProvider,
    max_concurrency: 4
  ]

  test "start_run/2 starts a RunWorker and exposes the run state" do
    run_id = unique_run_id()

    assert {:ok, %Run{id: ^run_id}} = Runs.start_run("Build Phase 4", @opts ++ [id: run_id])

    assert {:ok, %Run{id: ^run_id, task: "Build Phase 4"}} = Runs.get_run(run_id)
  end

  test "subscribe/1 receives PubSub events broadcast for the run" do
    run_id = unique_run_id()

    assert :ok = Runs.subscribe(run_id)
    assert :ok = Runs.broadcast(run_id, {:stage_chunk, %{role: :planner, chunk: "hello"}})

    assert_receive {:stage_chunk, %{run_id: ^run_id, role: :planner, chunk: "hello"}}
  end

  test "RunWorker updates state and broadcasts stage chunks" do
    run = Run.new("Manual run", id: unique_run_id(), provider: :ollama, model: "llama3.1")
    assert {:ok, pid} = RunWorker.start_link(run: run, opts: [], auto_start: false, name: nil)

    assert :ok = Runs.subscribe(run.id)

    send(pid, {:stage_started, %{role: :planner}})
    send(pid, {:stage_chunk, %{role: :planner, chunk: "chunk A"}})

    assert_receive {:stage_chunk, %{run_id: run_id, role: :planner, chunk: "chunk A"}}
    assert run_id == run.id

    assert {:ok, updated} = RunWorker.get_run(pid)
    assert updated.stages.planner.status == :streaming
    assert updated.stages.planner.content == "chunk A"
  end

  test "RunWorker updates state and broadcasts stage failures" do
    run = Run.new("Manual failure", id: unique_run_id(), provider: :openai, model: "gpt-4o")
    assert {:ok, pid} = RunWorker.start_link(run: run, opts: [], auto_start: false, name: nil)

    assert :ok = Runs.subscribe(run.id)

    send(pid, {:stage_started, %{role: :cloud_drafter}})
    send(pid, {:stage_failed, %{role: :cloud_drafter, error: :missing_api_key}})

    assert_receive {:stage_failed,
                    %{
                      run_id: run_id,
                      role: :cloud_drafter,
                      error: "The selected provider is missing its API key."
                    }}

    assert run_id == run.id

    assert {:ok, updated} = RunWorker.get_run(pid)
    assert updated.stages.cloud_drafter.status == :failed
    assert updated.stages.cloud_drafter.error == "The selected provider is missing its API key."
  end

  test "Orchestrator.stream/3 continues when one drafter fails" do
    Orchestrator.stream("Build resilient Phase 4", self(), @opts)

    assert_receive {:stage_failed, %{role: :cloud_drafter}}
    assert_receive {:stage_completed, %{role: :local_drafter}}
    assert_receive {:run_completed, %{final: "final from synth-model"}}
  end

  test "cancel_run/1 marks the run as cancelled" do
    run_id = unique_run_id()

    assert :ok = Runs.subscribe(run_id)

    assert {:ok, %Run{id: ^run_id}} =
             Runs.start_run("Long running task", @opts ++ [id: run_id, delay_ms: 1_000])

    assert_receive {:run_started, %{run_id: ^run_id}}

    assert :ok = Runs.cancel_run(run_id)
    assert_receive {:run_cancelled, %{run_id: ^run_id}}

    assert {:ok, %Run{status: :cancelled}} = Runs.get_run(run_id)
  end

  defp unique_run_id do
    "run-test-#{System.unique_integer([:positive])}"
  end
end
