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

  test "providers/0 exposes selectable UI providers without secrets" do
    assert [
             %{id: "openai", label: "OpenAI"},
             %{id: "grok", label: "Grok / xAI"},
             %{id: "openrouter", label: "OpenRouter"},
             %{id: "ollama", label: "Ollama"},
             %{id: "lmstudio", label: "LM Studio"}
           ] = Registry.providers()
  end

  test "models_for_provider/2 exposes provider-specific models and registry overrides" do
    registry = %{
      planner: [%{name: "local-planner", provider: :ollama, model: "mistral"}],
      drafts: [%{name: "local-draft", provider: :ollama, model: "qwen2.5-coder"}]
    }

    assert %{id: "gpt-4o"} = Registry.models_for_provider(:openai) |> List.first()

    assert [
             %{id: "mistral", label: "mistral"},
             %{id: "qwen2.5-coder", label: "qwen2.5-coder"}
             | _
           ] = Registry.models_for_provider(:ollama, registry: registry)
  end

  test "default_model/1 follows the selected provider" do
    assert Registry.default_model(:openai) == "gpt-4o"
    assert Registry.default_model(:ollama) == "llama3.1"
    assert Registry.default_model("lmstudio") == "local-model"
  end

  test "default_provider/0 uses the boot-resolved provider when none is pinned" do
    previous_provider = Application.get_env(:mr_eric, :ai_provider)
    previous_resolved = Application.get_env(:mr_eric, :resolved_default_provider)
    Application.delete_env(:mr_eric, :ai_provider)
    Application.put_env(:mr_eric, :resolved_default_provider, :lmstudio)

    on_exit(fn ->
      restore_env(:ai_provider, previous_provider)
      restore_env(:resolved_default_provider, previous_resolved)
    end)

    # An explicit AI_PROVIDER export on the host always wins over resolution.
    if System.get_env("AI_PROVIDER") do
      assert Registry.default_provider() == "openai" or
               Registry.default_provider() == String.downcase(System.get_env("AI_PROVIDER"))
    else
      assert Registry.default_provider() == "lmstudio"
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:mr_eric, key)
  defp restore_env(key, value), do: Application.put_env(:mr_eric, key, value)
end
