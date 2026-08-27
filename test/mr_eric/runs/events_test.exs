defmodule MrEric.Runs.EventsTest do
  use ExUnit.Case, async: true

  alias MrEric.Runs.Events

  test "tool_approval_expired is a recognised event name" do
    assert :tool_approval_expired in Events.names()
  end

  test "normalize_event accepts tool_approval_expired" do
    {event, payload} =
      Events.normalize_event("run-1",
        {:tool_approval_expired, %{approval_id: "a", reason: :ttl}})

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
end
