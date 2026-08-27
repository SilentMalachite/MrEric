defmodule MrEric.AgentTest do
  use ExUnit.Case, async: false

  alias MrEric.Agent

  # Minimal deterministic registry for driving Agent.execute/2, mirrors the
  # shape used in test/mr_eric/orchestrator_test.exs's @opts/@registry.
  @registry %{
    planner: [%{name: "planner", provider: :ollama, model: "planner-model"}],
    drafts: [%{name: "draft", provider: :ollama, model: "draft-model"}],
    reviewers: [%{name: "review", provider: :ollama, model: "review-model"}],
    synthesizer: [%{name: "synth", provider: :ollama, model: "synth-model"}]
  }

  @execute_opts [
    registry: @registry,
    provider_module: MrEric.LLM.FakeProvider,
    max_concurrency: 4
  ]

  defp start_agent(opts) do
    name = :"agent_#{System.unique_integer([:positive])}"
    start_supervised!({Agent, Keyword.put(opts, :name, name)})
    name
  end

  test "keeps only the newest max_history entries" do
    name = start_agent(max_history: 3)

    for n <- 1..10 do
      {:ok, _entry} = Agent.record(%{id: n, final: "run #{n}"}, server: name)
    end

    history = Agent.history(name)

    assert length(history) == 3
    assert Enum.map(history, & &1.id) == [10, 9, 8]
  end

  test "defaults to the configured run limit" do
    name = start_agent([])
    limit = MrEric.Runs.Limits.fetch!(:max_history_entries)

    for n <- 1..(limit + 5) do
      {:ok, _entry} = Agent.record(%{id: n, final: "run #{n}"}, server: name)
    end

    assert length(Agent.history(name)) == limit
  end

  test "keeps only the newest max_history entries via the execute/2 completion path" do
    name = start_agent(max_history: 3)

    for n <- 1..5 do
      assert {:ok, _entry} =
               Agent.execute("history task #{n}", Keyword.put(@execute_opts, :server, name))
    end

    history = Agent.history(name)

    assert length(history) == 3
    assert Enum.map(history, & &1.task) == ["history task 5", "history task 4", "history task 3"]
  end
end
