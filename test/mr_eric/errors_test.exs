defmodule MrEric.ErrorsTest do
  use ExUnit.Case

  alias MrEric.Errors

  test "classifies common provider and approval errors" do
    assert Errors.classify(:missing_api_key) == :missing_api_key
    assert Errors.classify(%{status: 404}) == :model_unavailable
    assert Errors.classify(:tool_denied) == :tool_denied
    assert Errors.classify(:approval_required) == :approval_required
    assert Errors.classify(:mcp_unavailable) == :mcp_unavailable
  end

  test "safe messages redact secret values" do
    message = Errors.to_safe_message("OPENAI_API_KEY=sk-dummysecret123456789")

    refute message =~ "sk-dummysecret"
    assert message =~ "[REDACTED]"
  end

  test "redacts nested maps and lists" do
    redacted =
      Errors.redact(%{
        output: ["Bearer dummy-token-123456", %{password: "secret-password"}],
        safe: "hello"
      })

    assert redacted.safe == "hello"
    assert redacted.output == ["Bearer [REDACTED]", %{password: "[REDACTED]"}]
  end

  test "classify/1 gives a refused run its own classification" do
    assert MrEric.Errors.classify(:too_many_runs) == :run_limit_reached
    assert :run_limit_reached in MrEric.Errors.classifications()
  end

  test "classify/1 treats an over-lifetime run as a timeout" do
    assert MrEric.Errors.classify(:run_lifetime_exceeded) == :timeout
  end

  test "to_safe_message/1 has a sentence for every classification" do
    for classification <- MrEric.Errors.classifications(), classification != :unknown do
      message = MrEric.Errors.to_safe_message(classification)
      assert is_binary(message) and message != ""
    end
  end
end
