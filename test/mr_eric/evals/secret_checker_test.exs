defmodule MrEric.Evals.SecretCheckerTest do
  use ExUnit.Case, async: true

  alias MrEric.Evals.SecretChecker
  alias MrEric.Evals.SecretChecker.Result

  describe "scan/1 — pattern matching" do
    test "detects sk- key in a string field" do
      assert %Result{status: :leak, findings: [finding]} =
               SecretChecker.scan(%{final: "OPENAI_API_KEY=sk-dummysecret123456789"})

      assert finding.reason == :pattern_match
      assert finding.path == [:final]
      refute finding.snippet =~ "sk-dummysecret"
    end

    test "detects bearer tokens nested inside trace entries" do
      trace = %{
        entries: [
          %{payload: %{result: %{output: "Authorization: Bearer dummy-token-1234567890"}}}
        ]
      }

      assert %Result{status: :leak, findings: findings} = SecretChecker.scan(%{trace: trace})
      assert Enum.any?(findings, &(&1.reason == :pattern_match))

      bearer = Enum.find(findings, &(&1.reason == :pattern_match))

      assert bearer.path ==
               [:trace, :entries, 0, :payload, :result, :output]
    end

    test "detects PEM private keys" do
      assert %Result{status: :leak, findings: findings} =
               SecretChecker.scan(%{
                 trace: %{
                   entries: [%{payload: "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"}]
                 }
               })

      assert Enum.any?(findings, &(&1.reason == :pattern_match))
    end
  end

  describe "scan/1 — sensitive-key alert" do
    test "fails when a sensitive key has a non-redacted, non-empty value" do
      assert %Result{status: :leak, findings: findings} =
               SecretChecker.scan(%{payload: %{password: "sk-real"}})

      assert Enum.any?(findings, fn f ->
               f.reason == :sensitive_key_unredacted and f.path == [:payload, :password]
             end)
    end

    test "passes when a sensitive key value is [REDACTED]" do
      assert %Result{status: :clean} =
               SecretChecker.scan(%{payload: %{password: "[REDACTED]"}})
    end

    test "passes when a sensitive key value is nil or empty" do
      assert %Result{status: :clean} = SecretChecker.scan(%{payload: %{password: nil}})
      assert %Result{status: :clean} = SecretChecker.scan(%{payload: %{password: ""}})
    end

    test "alerts even on api_key with placeholder-looking content if not exact" do
      assert %Result{status: :leak, findings: findings} =
               SecretChecker.scan(%{payload: %{api_key: "sk-fake"}})

      assert Enum.any?(findings, &(&1.reason == :sensitive_key_unredacted))
    end
  end

  describe "scan/1 — channel coverage (denylist)" do
    test "scans rag_context" do
      assert %Result{status: :leak} =
               SecretChecker.scan(%{rag_context: "OPENAI_API_KEY=sk-leakedfromrag"})
    end

    test "scans changed_files" do
      assert %Result{status: :leak, findings: findings} =
               SecretChecker.scan(%{changed_files: [%{path: "x", diff: "sk-secretindiff123"}]})

      assert Enum.any?(findings, &(&1.path == [:changed_files, 0, :diff]))
    end

    test "scans tool_args" do
      assert %Result{status: :leak} =
               SecretChecker.scan(%{tool_args: %{command: "echo sk-secretincmd123"}})
    end

    test "ignores pure metadata fields" do
      assert %Result{status: :clean} =
               SecretChecker.scan(%{
                 status: :completed,
                 duration_ms: 123,
                 case_id: "x",
                 stage_durations: %{planner: 10}
               })
    end
  end

  describe "scan/1 — type handling" do
    test "does not raise on DateTime" do
      assert %Result{status: :clean} =
               SecretChecker.scan(%{trace: %{started_at: DateTime.utc_now()}})
    end

    test "does not raise on tuples and recurses through them" do
      assert %Result{status: :leak} =
               SecretChecker.scan(%{trace: {:ok, "OPENAI_API_KEY=sk-tupledleakvalue"}})
    end

    test "snippets never leak the full secret" do
      assert %Result{status: :leak, findings: findings} =
               SecretChecker.scan(%{final: "OPENAI_API_KEY=sk-dummysecret123456789"})

      Enum.each(findings, fn f ->
        refute f.snippet =~ "sk-dummysecret"
      end)
    end
  end

  describe "check/1 (legacy wrapper)" do
    test "returns :ok on clean input" do
      assert :ok = SecretChecker.check(%{final: "no secrets"})
    end

    test "returns {:error, leaks} on leak" do
      assert {:error, leaks} = SecretChecker.check(%{final: "sk-leakedaaaaaa1234567890"})
      assert is_list(leaks)
      assert length(leaks) >= 1
    end
  end
end
