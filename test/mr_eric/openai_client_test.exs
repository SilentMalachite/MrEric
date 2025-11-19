defmodule MrEric.OpenAIClientTest do
  use ExUnit.Case
  alias MrEric.OpenAIClient

  test "chat_completion/2 returns content" do
    response = OpenAIClient.chat_completion("Hello")
    assert response == "Mock response"
  end

  test "stream_completion/3 sends messages to pid" do
    OpenAIClient.stream_completion("Hello", self())
    
    assert_receive {:chunk, _content}
    assert_receive {:complete, :ok}
  end
end
