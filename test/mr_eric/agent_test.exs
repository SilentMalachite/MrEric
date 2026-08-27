defmodule MrEric.AgentTest do
  use ExUnit.Case, async: false

  alias MrEric.Agent

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
end
