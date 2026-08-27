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

  test "folds repeated stage chunks into one entry per role and counts the rest" do
    trace =
      Enum.reduce(1..1_000, Trace.new("run-fold", "task", :ollama, "m"), fn n, acc ->
        Trace.record(acc, :stage_chunk, %{role: :planner, chunk: "chunk #{n}"})
      end)

    chunk_entries = Enum.filter(trace.entries, &(&1.event == :stage_chunk))

    assert length(chunk_entries) == 1
    assert Trace.summary(trace).event_counts[:stage_chunk] == 1_000
    assert :stage_chunk in Trace.events(trace)
  end

  test "never keeps the streamed chunk text, which already lives in the stage" do
    trace =
      Trace.new("run-nochunk", "task", :ollama, "m")
      |> Trace.record(:stage_chunk, %{role: :planner, chunk: "secret-looking text"})

    [entry] = Enum.filter(trace.entries, &(&1.event == :stage_chunk))

    refute Map.has_key?(entry.payload, :chunk)
    assert entry.payload.role == :planner
  end

  test "counts chunks per role" do
    trace =
      Trace.new("run-roles", "task", :ollama, "m")
      |> Trace.record(:stage_chunk, %{role: :planner, chunk: "a"})
      |> Trace.record(:stage_chunk, %{role: :planner, chunk: "b"})
      |> Trace.record(:stage_chunk, %{role: :critic, chunk: "c"})

    chunk_entries = Enum.filter(trace.entries, &(&1.event == :stage_chunk))

    assert length(chunk_entries) == 2
    assert trace.chunk_counts == %{planner: 2, critic: 1}
    assert Trace.summary(trace).event_counts[:stage_chunk] == 3
  end

  test "caps entries and reports how many were dropped" do
    max = MrEric.Runs.Limits.fetch!(:max_trace_entries)

    trace =
      Enum.reduce(1..(max + 25), Trace.new("run-cap", "task", :ollama, "m"), fn n, acc ->
        Trace.record(acc, :stage_started, %{role: :planner, name: "agent-#{n}"})
      end)

    assert length(trace.entries) == max
    assert trace.dropped_entries == 25

    summary = Trace.summary(trace)
    assert summary.dropped_entries == 25
    assert summary.truncated?
  end

  test "an untruncated trace reports no drops" do
    trace =
      Trace.new("run-nodrop", "task", :ollama, "m")
      |> Trace.record(:run_started, %{task: "task"})
      |> Trace.record(:run_completed, %{final: "done"})

    summary = Trace.summary(trace)

    assert summary.dropped_entries == 0
    refute summary.truncated?
  end
end
