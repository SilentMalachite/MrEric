defmodule MrEric.Runs.RagFailedEventTest do
  use ExUnit.Case, async: true

  alias MrEric.Evals.SecretChecker
  alias MrEric.Runs.Events
  alias MrEric.Runs.Trace

  test ":rag_failed is part of the closed event vocabulary" do
    assert :rag_failed in Events.names()
  end

  test "normalize_event/2 sanitizes the reason and carries the classification" do
    {:rag_failed, payload} =
      Events.normalize_event("run-1", {:rag_failed, %{error: :rag_failed}})

    assert payload.run_id == "run-1"
    assert payload.error_class == :rag_failed
    assert is_binary(payload.error)
  end

  test "a secret in the raw reason does not survive normalization" do
    {:rag_failed, payload} =
      Events.normalize_event(
        "run-2",
        {:rag_failed, %{error: "index failed for OPENAI_API_KEY=sk-leakedsecret1234567890"}}
      )

    assert %SecretChecker.Result{status: :clean} = SecretChecker.scan(payload)
  end

  test "the trace entry carries the classification rather than re-deriving it" do
    {:rag_failed, payload} =
      Events.normalize_event("run-3", {:rag_failed, %{error: :rag_failed}})

    trace =
      "run-3"
      |> Trace.new("task", :fake, "fake-model")
      |> Trace.record(:rag_failed, payload)

    assert :rag_failed in Trace.events(trace)

    entry = Enum.find(trace.entries, &(&1.event == :rag_failed))
    assert entry.error_classification == :rag_failed
  end

  test "a rag_failed entry does not make the whole trace look like a failed run" do
    # `update_from_event/4` deliberately has no :rag_failed clause. A run that
    # completed with degraded context is not a failed run, and `summary/1`'s
    # error_classification answers "how did this run fail" -- so it stays nil.
    trace =
      "run-4"
      |> Trace.new("task", :fake, "fake-model")
      |> Trace.record(:rag_failed, %{error_class: :rag_failed, error: "context lookup failed"})
      |> Trace.record(:run_completed, %{})

    assert Trace.summary(trace).error_classification == nil
    assert Trace.summary(trace).status == :completed
  end
end
