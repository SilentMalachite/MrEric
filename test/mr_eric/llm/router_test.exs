defmodule MrEric.LLM.RouterTest do
  use ExUnit.Case

  alias MrEric.LLM.Router

  test "complete/3 routes prompt through the configured provider module with model opts" do
    agent = %{role: :draft, name: "draft-primary", provider: :ollama, model: "llama3"}

    assert {:ok, result} =
             Router.complete("Produce an implementation draft", agent,
               provider_module: MrEric.LLM.FakeProvider
             )

    assert result.agent == agent
    assert result.content == "draft from draft-primary"
  end

  test "complete/3 returns provider errors without raising" do
    agent = %{role: :draft, name: "draft-failing", provider: :ollama, model: "llama3", fail: true}

    assert {:error, %{agent: ^agent, reason: {:fake_failure, "draft-failing"}}} =
             Router.complete("Produce an implementation draft", agent,
               provider_module: MrEric.LLM.FakeProvider
             )
  end
end
