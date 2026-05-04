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

  describe "split_sse_events/1" do
    test "returns complete events and keeps the unfinished tail in the buffer" do
      assert {["data: a", "data: b"], "data: c"} =
               OpenAICompat.split_sse_events("data: a\n\ndata: b\n\ndata: c")
    end

    test "returns no events when the chunk has no terminator yet" do
      assert {[], "data: partial"} = OpenAICompat.split_sse_events("data: partial")
    end

    test "treats a trailing terminator as an empty tail" do
      assert {["data: a"], ""} = OpenAICompat.split_sse_events("data: a\n\n")
    end
  end

  describe "handle_sse_chunk/3" do
    test "buffers a JSON event split across two HTTP chunks" do
      pid = self()

      first =
        ~s|data: {"choices":[{"delta":{"con|

      second =
        ~s|tent":"hi"}}]}\n\ndata: [DONE]\n\n|

      resp = %Req.Response{status: 200, body: nil, private: %{}}
      req = %Req.Request{}

      assert {:cont, {_req1, resp1}} =
               OpenAICompat.handle_sse_chunk({:data, first}, {req, resp}, pid)

      refute_received {:chunk, _}
      refute_received {:complete, :ok}
      assert resp1.private.__sse_buffer__ == first

      assert {:cont, {_req2, resp2}} =
               OpenAICompat.handle_sse_chunk({:data, second}, {req, resp1}, pid)

      assert_received {:chunk, "hi"}
      assert_received {:complete, :ok}
      assert resp2.private.__sse_buffer__ == ""
    end

    test "ignores comment lines and unknown SSE fields" do
      pid = self()
      resp = %Req.Response{status: 200, body: nil, private: %{}}
      req = %Req.Request{}

      data =
        ~s|: keep-alive\nevent: ping\nid: 1\ndata: {"choices":[{"delta":{"content":"ok"}}]}\n\n|

      assert {:cont, {_req, resp1}} =
               OpenAICompat.handle_sse_chunk({:data, data}, {req, resp}, pid)

      assert_received {:chunk, "ok"}
      assert resp1.private.__sse_buffer__ == ""
    end
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
