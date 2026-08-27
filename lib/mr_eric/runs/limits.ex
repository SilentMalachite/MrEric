defmodule MrEric.Runs.Limits do
  @moduledoc """
  Resource limits that bound a run's lifetime and memory (Spec D).

  `@defaults` is the single source of truth for every value. Configuration is
  override-only:

      config :mr_eric, :run_limits,
        max_concurrent_runs: 16,
        terminal_run_ttl_ms: 30_000

  Any key left out keeps its default, so there is never a second copy of a
  number to drift.

  `fetch!/1` has no catch-all clause and no default parameter on purpose: an
  unknown key raises at the call site rather than returning a plausible
  number. Spec C-1 established the rule the hard way — `Map.get(table, key,
  [])` on a grammar lookup is what made an earlier deny-list fail open.
  """

  @defaults %{
    # Concurrently supervised RunWorkers. Counts workers, not streaming runs:
    # a finished run holds its slot until it is reaped.
    max_concurrent_runs: 8,
    # Grace period between a run reaching a terminal status and its worker
    # stopping. Long enough for a post-completion `Runs.get_run/1`.
    terminal_run_ttl_ms: 60_000,
    # Added to the orchestrator's `max_total_runtime_ms` to form the absolute
    # deadline after which a worker terminalises itself no matter what.
    hard_deadline_grace_ms: 60_000,
    # Backstop on `MrEric.Runs.Trace` entries. Chunk folding keeps a normal
    # run well under this.
    max_trace_entries: 500,
    # Longest string a single trace payload value keeps. An entry cap counts
    # entries; this is what makes the count a memory bound, because the bodies
    # that reach a trace -- model output, tool output -- have no size the trace
    # controls. The model's own view of tool output is bounded separately by
    # the orchestrator's `max_tool_output_chars`; this is the diagnostic copy.
    max_trace_payload_chars: 2_000,
    # Completed runs kept by `MrEric.Agent` and mirrored in the LiveView.
    max_history_entries: 50
  }

  @doc "The built-in defaults, keyed by limit name."
  def defaults, do: @defaults

  @doc """
  Returns the configured value for `key`, or its built-in default.

  Raises `FunctionClauseError` for an unsupported key.
  """
  def fetch!(key) when is_map_key(@defaults, key) do
    :mr_eric
    |> Application.get_env(:run_limits, [])
    |> Keyword.get(key, Map.fetch!(@defaults, key))
  end
end
