defmodule MrEric.OpenAIClientTest do
  use ExUnit.Case
  alias MrEric.OpenAIClient

  test "chat_completion/2 returns content with default model" do
    assert {:ok, "Mock response"} = OpenAIClient.chat_completion("Hello")
  end

  test "chat_completion/2 accepts custom model option" do
    assert {:ok, "Mock response"} = OpenAIClient.chat_completion("Hello", model: "gpt-3.5-turbo")
  end

  test "stream_completion/3 sends messages to pid with default model" do
    OpenAIClient.stream_completion("Hello", self())

    assert_receive {:chunk, _content}
    assert_receive {:complete, :ok}
  end

  test "stream_completion/3 accepts custom model option" do
    OpenAIClient.stream_completion("Hello", self(), model: "gpt-4-turbo")

    assert_receive {:chunk, _content}
    assert_receive {:complete, :ok}
  end
end
