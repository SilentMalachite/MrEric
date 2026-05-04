defmodule MrEric.LLM.OpenAICompatTest do
  use ExUnit.Case

  alias MrEric.OpenAIClient
  alias MrEric.LLM.OpenAICompat

  test "provider behaviour defines the LLM contract" do
    assert {:chat_completion, 2} in MrEric.LLM.Provider.behaviour_info(:callbacks)
    assert {:stream_completion, 3} in MrEric.LLM.Provider.behaviour_info(:callbacks)
    assert {:list_models, 2} in MrEric.LLM.Provider.behaviour_info(:callbacks)
  end

  test "chat_completion/2 accepts provider and model options" do
    assert {:ok, "model:llama3"} =
             OpenAICompat.chat_completion("report model", provider: :ollama, model: "llama3")
  end

  test "list_models/2 fetches models from the provider models endpoint" do
    assert {:ok, models} = OpenAICompat.list_models(:openai, [])

    assert [%{"id" => "gpt-4o"}, %{"id" => "gpt-4o-mini"}] = models
  end

  test "OpenAIClient remains a backward-compatible wrapper for provider and model opts" do
    assert {:ok, "model:llama3"} =
             OpenAIClient.chat_completion("report model", provider: :ollama, model: "llama3")
  end

  test "OpenAIClient exposes list_models/2" do
    assert {:ok, models} = OpenAIClient.list_models(:openai, [])

    assert Enum.map(models, & &1["id"]) == ["gpt-4o", "gpt-4o-mini"]
  end

  test "parse_chat_message/1 preserves OpenAI-compatible tool_calls" do
    response = %{
      "choices" => [
        %{
          "message" => %{
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call-1",
                "function" => %{
                  "name" => "file_read",
                  "arguments" => ~s({"path":"README.md"})
                }
              }
            ]
          }
        }
      ]
    }

    assert %{
             content: "",
             tool_calls: [%{"id" => "call-1"}]
           } = OpenAICompat.parse_chat_message(response)
  end
end
