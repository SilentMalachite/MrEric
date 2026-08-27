defmodule MrEric.Runs.LimitsTest do
  # async: false — these tests mutate application env.
  use ExUnit.Case, async: false

  alias MrEric.Runs.Limits

  setup do
    original = Application.get_env(:mr_eric, :run_limits)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:mr_eric, :run_limits)
        value -> Application.put_env(:mr_eric, :run_limits, value)
      end
    end)

    :ok
  end

  test "every key falls back to its built-in default when nothing is configured" do
    Application.put_env(:mr_eric, :run_limits, [])

    assert Limits.fetch!(:max_concurrent_runs) == 8
    assert Limits.fetch!(:terminal_run_ttl_ms) == 60_000
    assert Limits.fetch!(:hard_deadline_grace_ms) == 60_000
    assert Limits.fetch!(:max_trace_entries) == 500
    assert Limits.fetch!(:max_history_entries) == 50
  end

  test "an override wins for its own key and leaves the others at their defaults" do
    Application.put_env(:mr_eric, :run_limits, max_concurrent_runs: 2)

    assert Limits.fetch!(:max_concurrent_runs) == 2
    assert Limits.fetch!(:max_trace_entries) == 500
  end

  test "an unknown key raises instead of inventing a default" do
    assert_raise FunctionClauseError, fn -> Limits.fetch!(:max_bananas) end
  end

  test "defaults/0 exposes exactly the supported keys" do
    assert Map.keys(Limits.defaults()) |> Enum.sort() == [
             :hard_deadline_grace_ms,
             :max_concurrent_runs,
             :max_history_entries,
             :max_trace_entries,
             :terminal_run_ttl_ms
           ]
  end
end
