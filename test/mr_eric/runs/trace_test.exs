defmodule MrEric.Runs.TraceTest do
  use ExUnit.Case

  alias MrEric.Runs.Trace

  test "records redacted run and tool events with a useful summary" do
    trace =
      Trace.new("run-trace", "task", :fake, "fake-model")
      |> Trace.record(:run_started, %{task: "task"})
      |> Trace.record(:stage_started, %{role: :planner})
      |> Trace.record(:tool_approval_requested, %{
        tool: :apply_patch,
        tool_call_id: "call-1",
        args: %{changes: [%{path: "note.txt"}]}
      })
      |> Trace.record(:tool_completed, %{
        tool: :apply_patch,
        tool_call_id: "call-1",
        result: %{applied?: true, changed_files: ["note.txt"], output: "sk-dummysecret123"}
      })
      |> Trace.record(:run_completed, %{final: "done"})

    summary = Trace.summary(trace)

    assert summary.status == :completed
    assert summary.event_counts.run_completed == 1
    assert summary.patch_applied? == true
    assert summary.changed_files == ["note.txt"]
    refute inspect(trace) =~ "sk-dummysecret"
    assert inspect(trace) =~ "[REDACTED]"
  end

  test "classifies failures in trace metadata" do
    trace =
      Trace.new("run-trace-failed", "task", :fake, "fake-model")
      |> Trace.record(:run_failed, %{error: :missing_api_key})

    assert trace.error_classification == :missing_api_key
    assert Trace.summary(trace).status == :failed
  end
end
