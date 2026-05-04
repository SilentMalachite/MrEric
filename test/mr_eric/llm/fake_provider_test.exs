defmodule MrEric.LLM.FakeProviderTest do
  use ExUnit.Case

  alias MrEric.LLM.FakeProvider

  test "responds deterministically for the same prompt and scenario" do
    opts = [scenario: "simple_planning", role: :planner, model: "fake-model"]

    assert FakeProvider.chat_completion("Create a concise implementation plan", opts) ==
             FakeProvider.chat_completion("Create a concise implementation plan", opts)
  end

  test "can vary responses by role through a script" do
    script = %{
      :planner => "scripted plan",
      "synthesizer" => %{content: "scripted final"}
    }

    assert {:ok, "scripted plan"} =
             FakeProvider.chat_completion("anything", script: script, role: :planner)

    assert {:ok, %{content: "scripted final", tool_calls: []}} =
             FakeProvider.chat_completion("anything", script: script, role: :synthesizer)
  end

  test "returns deterministic tool calls for tool scenarios" do
    assert {:ok, %{tool_calls: [call]}} =
             FakeProvider.chat_completion("Create a concise implementation plan",
               scenario: "tool_denied",
               role: :planner
             )

    assert get_in(call, ["function", "name"]) == "phase9_unknown_tool"
    assert is_binary(get_in(call, ["function", "arguments"]))
  end

  test "can return configured role failures" do
    assert {:error, {:fake_failure, :local_drafter}} =
             FakeProvider.chat_completion("Produce an implementation draft",
               fail_role: :local_drafter,
               role: :local_drafter
             )
  end

  test "streams configured chunks without calling external APIs" do
    assert :ok =
             FakeProvider.stream_completion("ignored", self(),
               stream_chunks: ["one", "two"],
               role: :planner
             )

    assert_receive {:chunk, "one"}
    assert_receive {:chunk, "two"}
    assert_receive {:complete, :ok}
  end
end
