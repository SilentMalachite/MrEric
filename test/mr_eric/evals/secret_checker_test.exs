defmodule MrEric.Evals.SecretCheckerTest do
  use ExUnit.Case

  alias MrEric.Evals.SecretChecker

  test "detects dummy API keys without returning the secret value" do
    assert {:error, leaks} =
             SecretChecker.check(%{final: "OPENAI_API_KEY=sk-dummysecret123456789"})

    assert Enum.any?(leaks, &(&1.type == :named_api_key))
    refute inspect(leaks) =~ "sk-dummysecret"
  end

  test "detects bearer tokens and private keys in nested trace output" do
    trace = %{
      entries: [
        %{payload: %{result: %{output: "Authorization: Bearer dummy-token-1234567890"}}},
        %{payload: "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"}
      ]
    }

    assert {:error, leaks} = SecretChecker.check(trace)
    assert Enum.any?(leaks, &(&1.type == :bearer_token))
    assert Enum.any?(leaks, &(&1.type == :private_key))
  end

  test "accepts safe output" do
    assert :ok = SecretChecker.check(%{final: "No secrets here", trace: []})
  end
end
