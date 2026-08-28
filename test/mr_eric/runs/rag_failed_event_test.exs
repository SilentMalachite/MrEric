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

  test "re-normalizing a normalized event keeps the classification" do
    # `normalize_event/2` still cannot recover a raw reason it has already
    # replaced with a sentence -- that is why `Events.publish/2` exists. But it
    # must not *destroy* the classification either: the answer taken while the
    # reason existed travels in `:error_class`, and every second pass keeps it.
    # Without that, any subscriber that normalizes what it received -- the
    # LiveView does, as a redaction backstop -- downgraded every class to
    # `:unknown`.
    for {reason, class} <- [rag_failed: :rag_failed, run_lifetime_exceeded: :timeout] do
      {event, once} = Events.normalize_event("run-x", {:run_failed, %{error: reason}})
      {^event, twice} = Events.normalize_event("run-x", {:run_failed, once})

      assert once.error_class == class
      assert twice.error_class == class
      assert twice.error == once.error
    end
  end

  test "re-deriving a classification from the sentence is what it protects against" do
    # The reason the carried class matters: `classify/1` on the sentence is
    # keyword-matching against English, and answers `:unknown`.
    {:run_failed, once} =
      Events.normalize_event("run-y", {:run_failed, %{error: :run_lifetime_exceeded}})

    assert MrEric.Errors.classify(once.error) == :unknown
  end

  test "a bogus incoming error_class is not trusted" do
    {:run_failed, payload} =
      Events.normalize_event(
        "run-z",
        {:run_failed, %{error: :rag_failed, error_class: :not_a_classification}}
      )

    assert payload.error_class == :rag_failed
  end

  test "a subscriber receives the classification the run recorded, not a re-derived one" do
    run_id = "rag-failed-pubsub-#{System.unique_integer([:positive])}"
    :ok = MrEric.Runs.subscribe(run_id)
    on_exit(fn -> MrEric.Runs.unsubscribe(run_id) end)

    {event, payload} =
      Events.normalize_event(run_id, {:rag_failed, %{error: :rag_failed, stage: :planner}})

    # Exactly what RunWorker does after applying the event to the run.
    Events.publish(run_id, {event, payload})

    assert_receive {:rag_failed, received}, 1_000
    assert received.error_class == :rag_failed
    assert received.error == "Project context lookup failed."
    assert received == payload
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
