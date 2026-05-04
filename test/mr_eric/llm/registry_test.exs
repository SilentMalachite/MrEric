defmodule MrEric.LLM.RegistryTest do
  use ExUnit.Case

  alias MrEric.LLM.Registry

  test "agents/2 returns normalized role specs from opts" do
    registry = %{
      planner: [%{name: "planner", provider: :ollama, model: "llama3"}],
      drafts: [
        %{name: "draft-primary", provider: :openai, model: "gpt-4o"},
        %{name: "draft-local", provider: :ollama, model: "qwen2.5"}
      ]
    }

    assert [
             %{role: :planner, name: "planner", provider: :ollama, model: "llama3"}
           ] = Registry.agents(:planner, registry: registry)

    assert [
             %{role: :draft, name: "draft-primary", provider: :openai, model: "gpt-4o"},
             %{role: :draft, name: "draft-local", provider: :ollama, model: "qwen2.5"}
           ] = Registry.agents(:draft, registry: registry)
  end

  test "agents/2 provides default planner, draft, reviewer, and synthesizer roles" do
    assert [%{role: :planner}] = Registry.agents(:planner)
    assert [%{role: :draft} | _] = Registry.agents(:draft)
    assert [%{role: :reviewer} | _] = Registry.agents(:reviewer)
    assert [%{role: :synthesizer}] = Registry.agents(:synthesizer)
  end
end
