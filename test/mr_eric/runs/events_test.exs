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
end
