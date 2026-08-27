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

  # Every event a RunWorker records has been through
  # `Events.normalize_event/2` first, so `:error` is a sentence and
  # `:error_class` is the classification taken while the raw reason was still
  # known. Re-deriving one from the sentence is what made a run stopped at its
  # absolute deadline classify as `:unknown`.
  describe "a normalized payload's classification" do
    test "is preferred over re-deriving one from the sanitized message" do
      trace =
        Trace.new("run-normalized", "task", :fake, "fake-model")
        |> Trace.record(:run_failed, %{
          error: "The run exceeded its maximum lifetime and was stopped.",
          error_class: :timeout
        })

      assert trace.error_classification == :timeout
      assert List.last(trace.entries).error_classification == :timeout
    end

    test "still falls back to the reason when no classification was carried" do
      trace =
        Trace.new("run-unnormalized", "task", :fake, "fake-model")
        |> Trace.record(:stage_failed, %{role: :planner, error: :econnrefused})

      assert trace.error_classification == :provider_unavailable
    end

    test "is ignored when it is not a real classification" do
      trace =
        Trace.new("run-bogus-class", "task", :fake, "fake-model")
        |> Trace.record(:run_failed, %{error: :missing_api_key, error_class: :nonsense})

      assert trace.error_classification == :missing_api_key
    end
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
    # Drop-oldest, not drop-newest: the 25 oldest entries (agent-1..agent-25)
    # are gone, so the first surviving entry is the 26th thing pushed.
    assert List.first(trace.entries).payload.name == "agent-26"

    summary = Trace.summary(trace)
    assert summary.dropped_entries == 25
    assert summary.truncated?
  end

  test "pushing exactly the cap causes no drops" do
    max = MrEric.Runs.Limits.fetch!(:max_trace_entries)

    trace =
      Enum.reduce(1..max, Trace.new("run-cap-exact", "task", :ollama, "m"), fn n, acc ->
        Trace.record(acc, :stage_started, %{role: :planner, name: "agent-#{n}"})
      end)

    assert length(trace.entries) == max
    assert trace.dropped_entries == 0

    summary = Trace.summary(trace)
    assert summary.dropped_entries == 0
    refute summary.truncated?
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

  # An entry cap is a count, not a memory bound. The bodies that reach a trace
  # are model output and tool output, and neither has a size the trace itself
  # controls -- so a 500-entry cap still admits an unbounded number of bytes.
  describe "payload size" do
    @big String.duplicate("x", 50_000)

    test "never keeps the completed stage text, which already lives in the stage" do
      trace =
        Trace.new("run-stage-body", "task", :ollama, "m")
        |> Trace.record(:stage_completed, %{role: :planner, content: @big})

      [entry] = trace.entries
      assert entry.event == :stage_completed
      assert entry.payload.role == :planner
      refute Map.has_key?(entry.payload, :content)
    end

    test "truncates an oversized tool output rather than storing it whole" do
      max = MrEric.Runs.Limits.fetch!(:max_trace_payload_chars)

      trace =
        Trace.new("run-tool-body", "task", :ollama, "m")
        |> Trace.record(:tool_completed, %{
          tool: :shell_command,
          tool_call_id: "call-1",
          result: %{output: @big, exit_status: 0}
        })

      [entry] = trace.entries
      output = entry.payload.result.output

      assert String.length(output) <= max + 32
      assert String.starts_with?(output, "xxxx")
      assert output =~ "truncated"
      assert entry.payload.result.exit_status == 0
    end

    test "keeps the small values a summary is built from intact" do
      trace =
        Trace.new("run-summary-intact", "task", :ollama, "m")
        |> Trace.record(:tool_completed, %{
          tool: :apply_patch,
          tool_call_id: "call-1",
          result: %{applied?: true, changed_files: ["note.txt"], output: @big}
        })

      summary = Trace.summary(trace)

      assert summary.patch_applied? == true
      assert summary.changed_files == ["note.txt"]
    end

    test "bounds the whole trace even when every entry carries an oversized body" do
      max_entries = MrEric.Runs.Limits.fetch!(:max_trace_entries)

      trace =
        Enum.reduce(1..(max_entries * 2), Trace.new("run-total", "task", :ollama, "m"), fn i,
                                                                                           acc ->
          Trace.record(acc, :tool_completed, %{
            tool: :shell_command,
            tool_call_id: "call-#{i}",
            result: %{output: @big}
          })
        end)

      # Each of the 50_000-char bodies alone would be ~50 KB; 500 of them is
      # ~25 MB. The bound has to hold on the stored trace, not on one entry.
      assert :erlang.external_size(trace) < 5_000_000
    end
  end
end
