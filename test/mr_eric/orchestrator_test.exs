defmodule MrEric.OrchestratorTest do
  use ExUnit.Case

  alias MrEric.Agent
  alias MrEric.Orchestrator

  @registry %{
    planner: [%{name: "planner", provider: :ollama, model: "planner-model"}],
    drafts: [
      %{name: "draft-good", provider: :ollama, model: "draft-model"},
      %{name: "draft-bad", provider: :ollama, model: "draft-model", fail: true}
    ],
    reviewers: [
      %{name: "review-good", provider: :ollama, model: "review-model"},
      %{name: "review-bad", provider: :ollama, model: "review-model", fail: true}
    ],
    synthesizer: [%{name: "synth", provider: :ollama, model: "synth-model"}]
  }

  @opts [
    registry: @registry,
    provider_module: MrEric.LLM.FakeProvider,
    max_concurrency: 4
  ]

  test "run/2 executes planner, draft agents, reviewers, and synthesizer" do
    assert {:ok, result} = Orchestrator.run("Build Phase 2", @opts)

    assert result.task == "Build Phase 2"
    assert result.plan == "plan from planner-model"
    assert result.final == "final from synth-model"
    assert [%{content: "draft from draft-good"}] = result.drafts
    assert [%{content: "review from review-good"}] = result.reviews
  end

  test "run/2 keeps going when some draft and review models fail" do
    assert {:ok, result} = Orchestrator.run("Build resilient flow", @opts)

    assert [%{agent: %{name: "draft-bad"}, reason: {:fake_failure, "draft-bad"}}] =
             result.draft_errors

    assert [%{agent: %{name: "review-bad"}, reason: {:fake_failure, "review-bad"}}] =
             result.review_errors

    assert result.final == "final from synth-model"
  end

  test "run/2 falls back to the best draft when synthesis fails" do
    registry =
      put_in(@registry, [:synthesizer], [%{name: "synth-bad", model: "synth", fail: true}])

    assert {:ok, result} =
             Orchestrator.run("Build with fallback", Keyword.put(@opts, :registry, registry))

    assert result.final == "draft from draft-good"

    assert %{agent: %{name: "synth-bad"}, reason: {:fake_failure, "synth-bad"}} =
             result.synthesis_error
  end

  test "Agent.execute/2 delegates to Orchestrator.run/2 and keeps code equal to final" do
    server = :"agent_#{System.unique_integer([:positive])}"
    start_supervised!({Agent, name: server})

    assert {:ok, entry} = Agent.execute("Keep UI compatible", Keyword.put(@opts, :server, server))

    assert entry.final == "final from synth-model"
    assert entry.code == entry.final
    assert entry.plan == "plan from planner-model"
  end
end
