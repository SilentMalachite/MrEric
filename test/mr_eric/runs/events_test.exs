defmodule MrEric.Runs.EventsTest do
  use ExUnit.Case, async: true

  alias MrEric.Runs.Events

  test "tool_approval_expired is a recognised event name" do
    assert :tool_approval_expired in Events.names()
  end

  test "normalize_event accepts tool_approval_expired" do
    {event, payload} =
      Events.normalize_event(
        "run-1",
        {:tool_approval_expired, %{approval_id: "a", reason: :ttl}}
      )

    assert event == :tool_approval_expired
    assert payload.run_id == "run-1"
    assert payload.approval_id == "a"
    assert payload.reason == :ttl
  end

  test "public_error/1 explains a refused run without leaking OTP internals" do
    message = MrEric.Runs.Events.public_error(:too_many_runs)

    assert is_binary(message)
    assert message =~ "Too many recent runs"

    # The cap counts workers, not streaming runs, so the copy must stay true
    # when every blocking run has already finished and is only waiting to be
    # reaped -- it must not tell the user to wait for a run to finish.
    assert message =~ "slot to free up"
    refute message =~ "in progress"
    refute message =~ "max_children"
  end

  test "public_error/1 explains a run stopped at its absolute deadline" do
    message = MrEric.Runs.Events.public_error(:run_lifetime_exceeded)

    assert is_binary(message)
    assert message =~ "maximum lifetime"
  end

  # `sanitize_payload/2` is the one place that still has the raw reason: after
  # it runs, `:error` is a sentence written for a human, and re-deriving a
  # classification from that sentence is keyword-matching against English.
  # `MrEric.Errors.classify/1` knows the atom exactly, so the classification
  # has to be taken here and carried, not recovered downstream.
  describe "normalize_event/2 carries the error classification" do
    test "for an internal atom whose public message says nothing about it" do
      {:run_failed, payload} =
        MrEric.Runs.Events.normalize_event("r", {:run_failed, %{error: :run_lifetime_exceeded}})

      assert payload.error_class == :timeout
      # Precisely the point: the sanitized message alone does not classify.
      assert MrEric.Errors.classify(payload.error) == :unknown
    end

    test "for a provider error the public message rewords" do
      {:stage_failed, payload} =
        MrEric.Runs.Events.normalize_event("r", {:stage_failed, %{error: :econnrefused}})

      assert payload.error_class == :provider_unavailable
    end

    test "and always with a value from the closed classification list" do
      {:tool_failed, payload} =
        MrEric.Runs.Events.normalize_event("r", {:tool_failed, %{error: {:weird, self()}}})

      assert payload.error_class in MrEric.Errors.classifications()
    end

    test "but leaves events that carry no error alone" do
      {:run_completed, payload} =
        MrEric.Runs.Events.normalize_event("r", {:run_completed, %{final: "done"}})

      refute Map.has_key?(payload, :error_class)
    end
  end
end
