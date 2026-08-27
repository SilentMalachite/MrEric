# Spec E — Eval and RAG Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the golden eval harness capable of failing, and stop the RAG index being rebuilt and re-tokenized on every planner call.

**Architecture:** Fourteen tasks in three groups. Tasks 1–4 close the eval harness's early-pass paths (strict fixture parsing, no vacuous scorer passes, visible skips, the planner stage under the secret scanner). Tasks 5–9 add a fingerprint-validated ETS index cache bounded by measured bytes, plus the two `Retriever` changes that make caching worth its memory. Tasks 10–14 emit a real `:rag_failed` event and land the `rag_default_index` golden case that drives the actual `Index.build/1`.

**Tech Stack:** Elixir 1.20, Phoenix 1.8, ExUnit, ETS, GenServer. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-28-eval-rag-correctness-design.md`

## Global Constraints

- **Do not modify more than 3 files in one change.** Every task below is already inside that budget; do not merge tasks.
- **`mix precommit` must pass** — it is `compile --warning-as-errors` + `deps.unlock --unused` + `test`, run in `:test` env. Warnings are errors.
- **No new dependencies.** No `httpoison`/`tesla`/`httpc`; HTTP is `Req`. Nothing here needs HTTP.
- **No persistence.** No Ecto, no disk cache. All state is in memory and dies with its owning process.
- **Never give a lookup a silent default** where a boundary depends on it. `fetch!/1`-style functions have no catch-all clause and no default parameter; an unknown key raises at the call site.
- **Limit defaults live in exactly one `@defaults` map per contract**, and `config :mr_eric, <contract>` is override-only.
- **Never put API keys, auth headers, cookies, provider secrets, or `reply_to` pids** into PubSub events, assigns, templates, logs, traces, or eval output.
- **Evals must stay deterministic and offline.** `MrEric.LLM.FakeProvider` only; no network, no timing-dependent assertions.
- **Commit after every task** using the message given in the task's final step.

---

## File Structure

| File | Change | Responsibility after this plan |
|------|--------|-------------------------------|
| `lib/mr_eric/evals/case.ex` | modify | Parses a golden case **strictly**; unknown values raise. Owns the four vocabulary tables. |
| `lib/mr_eric/evals/scorer.ex` | modify | Scores a case against a readable trace; refuses to score without one. |
| `lib/mr_eric/evals.ex` | modify | Lists all cases, partitions enabled/skipped, reports skips. |
| `lib/mix/tasks/mr_eric.evals.ex` | modify | Prints passed/failed/**skipped**. |
| `lib/mr_eric/evals/runner.ex` | modify | Drives a case; seeds the workspace per scenario; returns the planner stage. |
| `lib/mr_eric/rag/chunker.ex` | modify | Produces chunks carrying `:terms` / `:path_terms`. |
| `lib/mr_eric/rag/retriever.ex` | modify | Scores from precomputed terms; applies `exact_bonus` to candidates only. |
| `lib/mr_eric/rag/index.ex` | modify | Builds the index **and** a cheap `fingerprint/1` from the same walk. |
| `lib/mr_eric/rag/cache.ex` | **create** | Owns the ETS cache, its key, its cost model, and its byte limits. |
| `lib/mr_eric/rag.ex` | modify | Fetch-or-build-and-put around `Index.build/1`. |
| `lib/mr_eric/application.ex` | modify | Starts `MrEric.RAG.Cache`. |
| `lib/mr_eric/runs/events.ex` | modify | Adds `:rag_failed` to the closed name list and to the sanitized set. |
| `lib/mr_eric/runs/trace.ex` | modify | Carries `:rag_failed`'s classification into the trace entry. |
| `lib/mr_eric/orchestrator.ex` | modify | Emits `:rag_failed` and continues with empty context. |
| `lib/mr_eric/llm/fake_provider.ex` | modify | Adds the `rag_default_index` scenario. |
| `priv/evals/phase9_golden_cases.json` | modify | Tightens `rag_failure_does_not_break_run`; adds `rag_default_index`. |

New test files: `test/mr_eric/evals/case_test.exs`, `test/mr_eric/evals/scorer_test.exs`, `test/mr_eric/rag/retriever_test.exs`, `test/mr_eric/rag/cache_test.exs`, `test/mr_eric/runs/rag_failed_event_test.exs`.

---

## Task 1: Strict eval-case parsing

Closes spec §1. Today `Case.from_map/1` turns an unrecognized status into `:completed`, drops an unrecognized event name from the list, and turns an unrecognized classification into `nil` — which is the value that switches the assertion off. A typo in a fixture makes the suite assert *less* and still report green.

**Files:**
- Modify: `lib/mr_eric/evals/case.ex`
- Modify: `lib/mr_eric/evals.ex:16` (the one call site)
- Test: `test/mr_eric/evals/case_test.exs` (create)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `MrEric.Evals.Case.from_map!/1 :: map() -> %MrEric.Evals.Case{}` (raises `ArgumentError`). `from_map/1` no longer exists. `MrEric.Evals.Case.enabled?/1 :: %Case{} -> boolean()` is unchanged.

- [ ] **Step 1: Write the failing test**

Create `test/mr_eric/evals/case_test.exs`:

```elixir
defmodule MrEric.Evals.CaseTest do
  use ExUnit.Case, async: true

  alias MrEric.Evals.Case, as: EvalCase

  defp base(extra \\ %{}) do
    Map.merge(%{"name" => "demo", "task" => "do a thing", "scenario" => "simple_planning"}, extra)
  end

  test "from_map!/1 fills documented defaults when optional fields are absent" do
    eval_case = EvalCase.from_map!(base())

    assert eval_case.name == "demo"
    assert eval_case.expected_status == :completed
    assert eval_case.expected_events == []
    assert eval_case.forbidden_events == []
    assert eval_case.requires == []
    assert eval_case.expected_no_secret_leak == true
    assert eval_case.expected_approval_required == false
    assert eval_case.expected_patch_applied == nil
    assert eval_case.expected_error_classification == nil
    assert eval_case.approval_action == nil
  end

  test "from_map!/1 raises on an unrecognized expected_status" do
    assert_raise ArgumentError, ~r/expected_status.*"faield"/, fn ->
      EvalCase.from_map!(base(%{"expected_status" => "faield"}))
    end
  end

  test "from_map!/1 raises on an unrecognized expected_events entry" do
    assert_raise ArgumentError, ~r/expected_events.*"run_compelted"/, fn ->
      EvalCase.from_map!(base(%{"expected_events" => ["run_started", "run_compelted"]}))
    end
  end

  test "from_map!/1 raises on an unrecognized forbidden_events entry" do
    assert_raise ArgumentError, ~r/forbidden_events.*"run_complete"/, fn ->
      EvalCase.from_map!(base(%{"forbidden_events" => ["run_complete"]}))
    end
  end

  test "from_map!/1 raises on an unrecognized expected_error_classification" do
    assert_raise ArgumentError, ~r/expected_error_classification.*"tiemout"/, fn ->
      EvalCase.from_map!(base(%{"expected_error_classification" => "tiemout"}))
    end
  end

  test "from_map!/1 raises on an unrecognized approval_action" do
    assert_raise ArgumentError, ~r/approval_action.*"aprove"/, fn ->
      EvalCase.from_map!(base(%{"approval_action" => "aprove"}))
    end
  end

  test "from_map!/1 raises on an unrecognized requires entry" do
    assert_raise ArgumentError, ~r/requires.*"rga"/, fn ->
      EvalCase.from_map!(base(%{"requires" => ["rga"]}))
    end
  end

  test "the raised message names the case so a broken fixture is findable" do
    assert_raise ArgumentError, ~r/"demo"/, fn ->
      EvalCase.from_map!(base(%{"expected_status" => "faield"}))
    end
  end

  test "the committed golden fixture parses" do
    # This is the regression guard: strict parsing must not reject the real file.
    assert is_list(MrEric.Evals.list_cases())
    assert length(MrEric.Evals.list_cases()) > 0
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/mr_eric/evals/case_test.exs`
Expected: FAIL — `MrEric.Evals.Case.from_map!/1 is undefined or private`.

- [ ] **Step 3: Replace the lenient parsers in `lib/mr_eric/evals/case.ex`**

Add a requirements table next to the other vocabulary tables (immediately after the `@classifications` map):

```elixir
  @requirements ~w(rag mcp)
```

Replace the whole `def from_map(map) when is_map(map) do … end` function with:

```elixir
  @doc """
  Builds a case from its JSON map, raising on any value it cannot recognize.

  Golden cases are fixtures in this repository, not user input. An *absent*
  optional field means "this case does not assert that", which is legal; a
  *present but unrecognized* one means the fixture is wrong. Lenient parsing
  used to turn the second into the first -- an unknown event name was dropped
  from the list, an unknown classification became `nil`, which is the value
  that switches `Scorer.assert_error_classification/3` off -- so a typo made
  the suite assert less and still report green.
  """
  def from_map!(map) when is_map(map) do
    name = string_field(map, "name")

    %__MODULE__{
      name: name,
      task: string_field(map, "task"),
      scenario: string_field(map, "scenario"),
      approval_action: approval_action!(name, Map.get(map, "approval_action")),
      cancel_after_ms: Map.get(map, "cancel_after_ms"),
      fail_role: Map.get(map, "fail_role"),
      requires: requires!(name, Map.get(map, "requires")),
      expected_status: status!(name, Map.get(map, "expected_status")),
      expected_final_contains: list_field(map, "expected_final_contains"),
      expected_events: events!(name, "expected_events", Map.get(map, "expected_events")),
      forbidden_events: events!(name, "forbidden_events", Map.get(map, "forbidden_events")),
      expected_no_secret_leak: Map.get(map, "expected_no_secret_leak", true),
      expected_approval_required: Map.get(map, "expected_approval_required", false),
      expected_tool_denied: Map.get(map, "expected_tool_denied", false),
      expected_tool_rejected: Map.get(map, "expected_tool_rejected", false),
      expected_patch_applied: Map.get(map, "expected_patch_applied"),
      expected_error_classification:
        classification!(name, Map.get(map, "expected_error_classification"))
    }
  end
```

Delete these four private functions entirely — `status/1` (all three clauses), `events/1` (both clauses), `approval_action/1` (all three clauses), and `classification/1` (all three clauses) — and put these in their place, at the bottom of the module just above `string_field/2`:

```elixir
  defp status!(_name, nil), do: :completed
  defp status!(_name, value) when is_atom(value), do: value

  defp status!(name, value) when is_binary(value) do
    case Map.fetch(@statuses, value) do
      {:ok, status} -> status
      :error -> bad!(name, "expected_status", value, Map.keys(@statuses))
    end
  end

  defp status!(name, value), do: bad!(name, "expected_status", value, Map.keys(@statuses))

  defp events!(_name, _field, nil), do: []

  defp events!(name, field, values) when is_list(values) do
    Enum.map(values, fn
      value when is_atom(value) ->
        value

      value when is_binary(value) ->
        case Map.fetch(@events, value) do
          {:ok, event} -> event
          :error -> bad!(name, field, value, Map.keys(@events))
        end

      value ->
        bad!(name, field, value, Map.keys(@events))
    end)
  end

  defp events!(name, field, value), do: bad!(name, field, value, Map.keys(@events))

  defp approval_action!(_name, nil), do: nil
  defp approval_action!(_name, value) when is_atom(value), do: value

  defp approval_action!(name, value) when is_binary(value) do
    case Map.fetch(@approval_actions, value) do
      {:ok, action} -> action
      :error -> bad!(name, "approval_action", value, Map.keys(@approval_actions))
    end
  end

  defp approval_action!(name, value),
    do: bad!(name, "approval_action", value, Map.keys(@approval_actions))

  defp classification!(_name, nil), do: nil
  defp classification!(_name, value) when is_atom(value), do: value

  defp classification!(name, value) when is_binary(value) do
    case Map.fetch(@classifications, value) do
      {:ok, classification} -> classification
      :error -> bad!(name, "expected_error_classification", value, Map.keys(@classifications))
    end
  end

  defp classification!(name, value),
    do: bad!(name, "expected_error_classification", value, Map.keys(@classifications))

  defp requires!(_name, nil), do: []

  defp requires!(name, values) when is_list(values) do
    Enum.map(values, fn
      value when is_binary(value) and value in @requirements -> value
      value -> bad!(name, "requires", value, @requirements)
    end)
  end

  defp requires!(name, value) when is_binary(value), do: requires!(name, [value])
  defp requires!(name, value), do: bad!(name, "requires", value, @requirements)

  defp bad!(case_name, field, value, allowed) do
    raise ArgumentError,
          "golden eval case #{inspect(case_name)}: unrecognized #{field} #{inspect(value)}. " <>
            "Allowed: #{Enum.map_join(Enum.sort(allowed), ", ", &inspect/1)}"
  end
```

Finally, delete the catch-all from the requirement table so an unhandled requirement is a loud `FunctionClauseError` rather than a silent disable. Remove this line:

```elixir
  defp requirement_available?(_requirement), do: false
```

`requires!/2` already guarantees only `"rag"` and `"mcp"` reach it, so the two remaining clauses are total. If you add a name to `@requirements`, you must add a `requirement_available?/1` clause for it in the same change.

- [ ] **Step 4: Update the single call site in `lib/mr_eric/evals.ex`**

On line 16, change:

```elixir
    |> Enum.map(&EvalCase.from_map/1)
```

to:

```elixir
    |> Enum.map(&EvalCase.from_map!/1)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/mr_eric/evals/case_test.exs test/mr_eric/evals_test.exs`
Expected: PASS. If "the committed golden fixture parses" fails, the fixture has a value the tables do not list — fix the fixture, not the parser.

- [ ] **Step 6: Run the full suite and the evals**

Run: `mix test && mix mr_eric.evals`
Expected: suite green; `passed=14 failed=0`.

- [ ] **Step 7: Commit**

```bash
git add lib/mr_eric/evals/case.ex lib/mr_eric/evals.ex test/mr_eric/evals/case_test.exs
git commit -m "fix(evals): raise on unrecognized golden-case expectations

An unknown event name was dropped from the list, an unknown
classification became nil -- the value that switches the assertion off --
and an unknown status became :completed. A fixture typo made the suite
assert less and still report green."
```

---

## Task 2: No vacuous scorer passes

Closes spec §2. `Scorer.trace_events/1` ends in a clause returning `[]`, so `assert_forbidden_events/3` evaluates `Enum.any?([], …)` — `false` — and passes. The assertion whose whole job is to prove an event did *not* happen is satisfied by not being able to see events at all.

**Files:**
- Modify: `lib/mr_eric/evals/scorer.ex`
- Test: `test/mr_eric/evals/scorer_test.exs` (create)

**Interfaces:**
- Consumes: `MrEric.Evals.Case.from_map!/1` from Task 1 (tests build `%EvalCase{}` structs directly, so no runtime dependency).
- Produces: `MrEric.Evals.Scorer.score/2` unchanged in arity and return shape. A new failure atom `:missing_trace` can appear in `failed_assertions`.

- [ ] **Step 1: Write the failing test**

Create `test/mr_eric/evals/scorer_test.exs`:

```elixir
defmodule MrEric.Evals.ScorerTest do
  use ExUnit.Case, async: true

  alias MrEric.Evals.Case, as: EvalCase
  alias MrEric.Evals.Scorer
  alias MrEric.Runs.Trace

  defp trace_with(events) do
    Enum.reduce(events, Trace.new("scorer-test", "task", :fake, "fake-model"), fn event, trace ->
      Trace.record(trace, event, %{})
    end)
  end

  test "a forbidden event that is absent still passes" do
    eval_case = %EvalCase{
      name: "ok",
      expected_status: :cancelled,
      forbidden_events: [:run_completed]
    }

    actual = %{status: :cancelled, final: "", trace: trace_with([:run_started, :run_cancelled])}

    assert {:ok, result} = Scorer.score(eval_case, actual)
    assert result.status == :passed
  end

  test "a forbidden event that is present fails" do
    eval_case = %EvalCase{
      name: "bad",
      expected_status: :cancelled,
      forbidden_events: [:run_completed]
    }

    actual = %{status: :cancelled, final: "", trace: trace_with([:run_started, :run_completed])}

    assert {:error, result} = Scorer.score(eval_case, actual)
    assert :forbidden_events in result.failed_assertions
  end

  test "an actual with no trace key fails with :missing_trace instead of passing" do
    eval_case = %EvalCase{
      name: "no_trace",
      expected_status: :cancelled,
      forbidden_events: [:run_completed]
    }

    assert {:error, result} = Scorer.score(eval_case, %{status: :cancelled, final: ""})
    assert result.failed_assertions == [:missing_trace]
  end

  test "an actual whose trace is nil fails with :missing_trace" do
    eval_case = %EvalCase{name: "nil_trace", expected_status: :cancelled}

    assert {:error, result} =
             Scorer.score(eval_case, %{status: :cancelled, final: "", trace: nil})

    assert result.failed_assertions == [:missing_trace]
  end

  test "the raw entries shape is still readable" do
    eval_case = %EvalCase{
      name: "entries",
      expected_status: :completed,
      expected_events: [:run_completed]
    }

    actual = %{
      status: :completed,
      final: "",
      trace: %{entries: [%{event: :run_started}, %{event: :run_completed}]}
    }

    assert {:ok, result} = Scorer.score(eval_case, actual)
    assert result.status == :passed
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/mr_eric/evals/scorer_test.exs`
Expected: the two `:missing_trace` tests FAIL — one reports `{:ok, …}` where `{:error, …}` was expected (that is the vacuous pass this task removes), the other reports a different failure list.

- [ ] **Step 3: Rewrite `score/2` and the assertion helpers in `lib/mr_eric/evals/scorer.ex`**

Replace the whole `def score(eval_case, actual) do … end` function with:

```elixir
  @doc """
  Scores `actual` against `eval_case`.

  The trace is read once, up front. An `actual` without a readable trace is
  not scored assertion-by-assertion: their verdicts on a missing trace are
  meaningless, and one of them -- `assert_forbidden_events/3`, on an empty
  event list -- used to come back *satisfied*.
  """
  def score(eval_case, actual) do
    case trace_view(actual) do
      {:ok, events, summary} ->
        failures =
          []
          |> assert_status(eval_case, actual)
          |> assert_final_contains(eval_case, actual)
          |> assert_events(eval_case, events)
          |> assert_forbidden_events(eval_case, events)
          |> assert_secret_free(eval_case, actual)
          |> assert_approval_required(eval_case, events)
          |> assert_tool_denied(eval_case, events)
          |> assert_tool_rejected(eval_case, events)
          |> assert_patch_applied(eval_case, summary)
          |> assert_error_classification(eval_case, summary)

        result(eval_case, actual, summary, failures)

      :error ->
        result(eval_case, actual, %{}, [:missing_trace])
    end
  end

  defp result(eval_case, actual, summary, []) do
    {:ok,
     %{
       case: eval_case.name,
       status: :passed,
       actual: actual,
       trace_summary: summary
     }}
  end

  defp result(eval_case, actual, summary, failures) do
    {:error,
     %{
       case: eval_case.name,
       status: :failed,
       failed_assertions: Enum.reverse(failures),
       expected: expected_summary(eval_case),
       actual: actual,
       trace_summary: summary
     }}
  end
```

Change the six event- and summary-reading assertions to take the already-extracted value instead of `actual`. Replace each function as shown:

```elixir
  defp assert_events(failures, eval_case, events) do
    if Enum.all?(eval_case.expected_events, &(&1 in events)) do
      failures
    else
      [:expected_events | failures]
    end
  end

  defp assert_forbidden_events(failures, eval_case, events) do
    if Enum.any?(eval_case.forbidden_events, &(&1 in events)) do
      [:forbidden_events | failures]
    else
      failures
    end
  end
```

```elixir
  defp assert_approval_required(failures, %{expected_approval_required: true}, events) do
    if :tool_approval_requested in events, do: failures, else: [:approval_required | failures]
  end

  defp assert_approval_required(failures, _eval_case, _events), do: failures

  defp assert_tool_denied(failures, %{expected_tool_denied: true}, events) do
    if :tool_denied in events, do: failures, else: [:tool_denied | failures]
  end

  defp assert_tool_denied(failures, _eval_case, _events), do: failures

  defp assert_tool_rejected(failures, %{expected_tool_rejected: true}, events) do
    if :tool_rejected in events, do: failures, else: [:tool_rejected | failures]
  end

  defp assert_tool_rejected(failures, _eval_case, _events), do: failures

  defp assert_patch_applied(failures, %{expected_patch_applied: nil}, _summary), do: failures

  defp assert_patch_applied(failures, %{expected_patch_applied: expected}, summary) do
    if Map.get(summary, :patch_applied?) == expected do
      failures
    else
      [:patch_applied | failures]
    end
  end

  defp assert_error_classification(
         failures,
         %{expected_error_classification: nil},
         _summary
       ),
       do: failures

  defp assert_error_classification(failures, eval_case, summary) do
    if Map.get(summary, :error_classification) == eval_case.expected_error_classification do
      failures
    else
      [:error_classification | failures]
    end
  end
```

Delete `trace_summary/1` (both clauses) and `trace_events/1` (all three clauses), and put this in their place:

```elixir
  # No catch-all. An `actual` this cannot read is reported as `:missing_trace`,
  # not scored against an empty event list -- `Enum.any?([], …)` is `false`, so
  # the "this event must not have happened" assertion used to pass precisely
  # when nothing could be observed.
  defp trace_view(%{trace: %Trace{} = trace}),
    do: {:ok, Trace.events(trace), Trace.summary(trace)}

  defp trace_view(%{trace: %{entries: entries}}) when is_list(entries),
    do: {:ok, Enum.map(entries, & &1.event), %{}}

  defp trace_view(_actual), do: :error
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/mr_eric/evals/scorer_test.exs`
Expected: PASS, all five.

- [ ] **Step 5: Run the full suite and the evals**

Run: `mix test && mix mr_eric.evals`
Expected: suite green; `passed=14 failed=0`.

- [ ] **Step 6: Commit**

```bash
git add lib/mr_eric/evals/scorer.ex test/mr_eric/evals/scorer_test.exs
git commit -m "fix(evals): stop scoring an actual with no readable trace

trace_events/1 ended in a clause returning [], so assert_forbidden_events
evaluated Enum.any?([], _) -- false -- and passed. The assertion whose job
is to prove an event did not happen was satisfied by not being able to see
events at all. Report :missing_trace instead."
```

---

## Task 3: Skipped cases are reported

Closes spec §3. `list_cases/0` filters by `enabled?/1` before anything counts, and `failed` is derived by subtraction from that already-filtered list. A single typo in `requires` used to remove a case from the suite with no trace in the output — Task 1 closed the typo route, and this task makes a legitimate skip visible too.

**Files:**
- Modify: `lib/mr_eric/evals.ex`
- Modify: `lib/mix/tasks/mr_eric.evals.ex`
- Test: `test/mr_eric/evals_test.exs`

**Interfaces:**
- Consumes: `MrEric.Evals.Case.from_map!/1` and `enabled?/1`.
- Produces:
  - `MrEric.Evals.list_cases/0 :: [] -> [%Case{}]` — now returns **all** cases, unfiltered.
  - `MrEric.Evals.partition_cases/0 :: [] -> {[%Case{}], [%Case{}]}` — `{enabled, skipped}`.
  - `MrEric.Evals.run_all/1` returns `{:ok, %{passed: integer, failed: integer, skipped: [%{case: String.t(), requires: [String.t()]}], results: [map]}}`.
  - `MrEric.Evals.run_case/2` returns `{:error, {:case_disabled, [String.t()]}}` for a known-but-disabled case.

- [ ] **Step 1: Write the failing test**

Append to `test/mr_eric/evals_test.exs`, inside the existing module:

```elixir
  test "list_cases/0 returns every case, including ones this machine cannot run" do
    all = Evals.list_cases()
    {enabled, skipped} = Evals.partition_cases()

    assert length(all) == length(enabled) + length(skipped)
    assert Enum.all?(enabled, &EvalCase.enabled?/1)
    refute Enum.any?(skipped, &EvalCase.enabled?/1)
  end

  test "run_all/1 reports skipped cases rather than dropping them" do
    assert {:ok, summary} = Evals.run_all()

    assert is_list(summary.skipped)
    assert summary.passed + summary.failed == length(summary.results)

    {_enabled, skipped} = Evals.partition_cases()
    assert length(summary.skipped) == length(skipped)

    Enum.each(summary.skipped, fn entry ->
      assert is_binary(entry.case)
      assert is_list(entry.requires)
    end)
  end

  test "run_case/2 distinguishes an unknown name from a disabled case" do
    assert {:error, :unknown_eval_case} = Evals.run_case("no_such_case_at_all")

    case Evals.partition_cases() do
      {_enabled, []} ->
        # Every case runs on this machine; the disabled branch is covered by
        # the unit below rather than by the fixture.
        :ok

      {_enabled, [disabled | _]} ->
        assert {:error, {:case_disabled, requires}} = Evals.run_case(disabled.name)
        assert requires == disabled.requires
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/mr_eric/evals_test.exs`
Expected: FAIL — `MrEric.Evals.partition_cases/0 is undefined`.

- [ ] **Step 3: Rewrite `lib/mr_eric/evals.ex`**

Replace `list_cases/0` and add `partition_cases/0`:

```elixir
  @doc """
  Every golden case in the fixture, runnable here or not.

  This deliberately does **not** filter by `enabled?/1`. Filtering before
  counting is what let `run_all/1` report `passed=13 failed=0` after a case
  quietly left the suite.
  """
  def list_cases do
    @cases_file
    |> eval_file()
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(&EvalCase.from_map!/1)
  end

  @doc "Splits the golden cases into `{runnable_here, skipped}`."
  def partition_cases do
    Enum.split_with(list_cases(), &EvalCase.enabled?/1)
  end
```

Replace `run_case/2`'s binary-name clause:

```elixir
  def run_case(name, opts) when is_binary(name) do
    case Enum.find(list_cases(), &(&1.name == name)) do
      nil ->
        {:error, :unknown_eval_case}

      eval_case ->
        if EvalCase.enabled?(eval_case) do
          run_case(eval_case, opts)
        else
          {:error, {:case_disabled, eval_case.requires}}
        end
    end
  end
```

Replace `run_all/1`:

```elixir
  def run_all(opts \\ []) do
    {enabled, skipped} = partition_cases()

    results =
      Enum.map(enabled, fn eval_case ->
        case run_case(eval_case, opts) do
          {:ok, result} -> result
          {:error, result} when is_map(result) -> result
          {:error, reason} -> %{case: eval_case.name, status: :failed, reason: reason}
        end
      end)

    # Counted, not subtracted: deriving `failed` as `length(results) - passed`
    # silently files any future third status under "failed".
    passed = Enum.count(results, &(&1.status == :passed))
    failed = Enum.count(results, &(&1.status != :passed))

    {:ok,
     %{
       passed: passed,
       failed: failed,
       skipped: Enum.map(skipped, &%{case: &1.name, requires: &1.requires}),
       results: results
     }}
  end
```

- [ ] **Step 4: Update `lib/mix/tasks/mr_eric.evals.ex`**

Replace `run_single/1` and `print_result/1`:

```elixir
  defp run_single(name) do
    case MrEric.Evals.run_case(name) do
      {:ok, result} ->
        {:ok, %{passed: 1, failed: 0, skipped: [], results: [result]}}

      {:error, {:case_disabled, requires}} ->
        {:ok, %{passed: 0, failed: 0, skipped: [%{case: name, requires: requires}], results: []}}

      {:error, result} when is_map(result) ->
        {:ok, %{passed: 0, failed: 1, skipped: [], results: [result]}}

      {:error, reason} ->
        {:ok,
         %{
           passed: 0,
           failed: 1,
           skipped: [],
           results: [%{case: name, status: :failed, reason: reason}]
         }}
    end
  end

  defp print_result({:ok, summary}) do
    Enum.each(summary.results, fn result ->
      Mix.shell().info("#{result.case}: #{result.status}")
    end)

    Enum.each(summary.skipped, fn skipped ->
      Mix.shell().info("#{skipped.case}: skipped (requires: #{Enum.join(skipped.requires, ", ")})")
    end)

    Mix.shell().info(
      "passed=#{summary.passed} failed=#{summary.failed} skipped=#{length(summary.skipped)}"
    )

    # A skip is a legitimate machine configuration, not a failure. It is only
    # forbidden from being invisible.
    if summary.failed > 0 do
      Mix.raise("MrEric evals failed")
    end
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/mr_eric/evals_test.exs`
Expected: PASS.

- [ ] **Step 6: Check the task output by hand**

Run: `mix mr_eric.evals`
Expected: the last line now reads `passed=14 failed=0 skipped=0`.

- [ ] **Step 7: Run the full suite**

Run: `mix test`
Expected: green.

- [ ] **Step 8: Commit**

```bash
git add lib/mr_eric/evals.ex lib/mix/tasks/mr_eric.evals.ex test/mr_eric/evals_test.exs
git commit -m "feat(evals): report skipped cases instead of dropping them

list_cases/0 filtered by enabled?/1 before anything counted and failed was
derived by subtraction, so a case that left the suite left no trace in the
output. Partition explicitly, count both sides, and print skipped=K."
```

---

## Task 4: The planner stage enters `actual`

Closes spec §4. `SecretChecker.scan/1` walks the whole `actual` map by denylist, so anything absent from `actual` is never scanned — and the planner stage, where RAG context lands, is absent. Task 13's golden case depends on this.

**Files:**
- Modify: `lib/mr_eric/evals/runner.ex`
- Test: `test/mr_eric/evals_test.exs`

**Interfaces:**
- Consumes: `MrEric.Evals.run_case/2`.
- Produces: the `actual` map gains `plan: %{content: String.t(), …}` (whatever `MrEric.Runs.Run.stage/2` returns for `:planner`).

- [ ] **Step 1: Write the failing test**

Append to `test/mr_eric/evals_test.exs`:

```elixir
  test "actual carries the planner stage so the secret scanner reaches it" do
    assert {:ok, result} = Evals.run_case("simple_planning")

    assert Map.has_key?(result.actual, :plan)
    assert is_binary(result.actual.plan.content)
    assert result.actual.plan.content != ""
  end

  test "a secret in planner output fails expected_no_secret_leak" do
    # Proves the new field is actually scanned, not merely present.
    eval_case = %EvalCase{
      name: "planted",
      expected_status: :completed,
      expected_no_secret_leak: true
    }

    actual = %{
      status: :completed,
      final: "",
      plan: %{content: "OPENAI_API_KEY=sk-plantedsecret1234567890"},
      trace: MrEric.Runs.Trace.new("planted", "task", :fake, "fake-model")
    }

    assert {:error, result} = Scorer.score(eval_case, actual)
    assert :secret_leak in result.failed_assertions
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/mr_eric/evals_test.exs`
Expected: the first new test FAILS — `actual` has no `:plan` key.

- [ ] **Step 3: Add the planner stage in `lib/mr_eric/evals/runner.ex`**

In `execute_case/3`, inside the `with` block's success branch, the returned map currently starts:

```elixir
        {:ok,
         %{
           status: run.status,
           final: run.final,
           trace: run.trace,
           changed_files: run.changed_files,
```

Add the planner stage immediately after `final:`, so the map reads:

```elixir
        {:ok,
         %{
           status: run.status,
           final: run.final,
           # The planner prompt is the only place RAG context reaches a model,
           # and `SecretChecker.scan/1` walks `actual` by denylist -- a field
           # that is not here is a field that is never scanned.
           plan: Run.stage(run, :planner),
           trace: run.trace,
           changed_files: run.changed_files,
```

`Run` is already aliased in this module, and `Run.stage/2` is already used just below for the drafts and reviews. No other change.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/mr_eric/evals_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full suite and the evals**

Run: `mix test && mix mr_eric.evals`
Expected: suite green; `passed=14 failed=0 skipped=0`. If any case newly fails on `:secret_leak`, that is a real finding — stop and surface it rather than removing the field.

- [ ] **Step 6: Commit**

```bash
git add lib/mr_eric/evals/runner.ex test/mr_eric/evals_test.exs
git commit -m "feat(evals): put the planner stage under the secret scanner

SecretChecker walks actual by denylist, so a field absent from actual is
never scanned -- and the planner stage, where RAG context lands, was
absent."
```

---

## Task 5: Chunks carry their term frequencies

Starts spec §5e. `Retriever.score/3` recomputes `content |> tokenize() |> Enum.frequencies()` for every chunk on every search; that work is a pure function of the chunk.

**Read this before writing code.** `Retriever.tokenize/1` ends in `Enum.uniq/1`, and `score/3` calls `Enum.frequencies/1` on that *already-deduplicated* list — so every "frequency" in the shipping scorer is `1`, and the lexical score counts distinct query tokens present, not occurrences. `:terms` must reproduce that exactly. Storing real occurrence counts would change every ranking, which the spec puts out of scope (§8). Keep the `Enum.uniq/1`.

**Files:**
- Modify: `lib/mr_eric/rag/chunker.ex`
- Test: `test/mr_eric/rag/chunker_test.exs`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - Each chunk map gains `terms: %{String.t() => 1}` and `path_terms: %{String.t() => 1}`.
  - `MrEric.RAG.Chunker.term_frequencies/1 :: String.t() -> %{String.t() => pos_integer()}` — public, so `Retriever` can use it for its fallback clause in Task 6.

- [ ] **Step 1: Write the failing test**

Append to `test/mr_eric/rag/chunker_test.exs`:

```elixir
  test "chunks carry precomputed terms for content and path" do
    [chunk | _] =
      Chunker.chunk_text("lib/mr_eric/tools/policy.ex", "approval gate keeps shell commands safe\n")

    assert chunk.terms["approval"] == 1
    assert chunk.terms["shell"] == 1
    assert chunk.path_terms["policy"] == 1
    assert chunk.path_terms["mr_eric"] == 1
  end

  test "terms drop tokens shorter than two characters, like the retriever's tokenizer" do
    [chunk | _] = Chunker.chunk_text("a.ex", "a bb ccc\n")

    refute Map.has_key?(chunk.terms, "a")
    assert chunk.terms["bb"] == 1
    assert chunk.terms["ccc"] == 1
  end

  test "term_frequencies/1 counts each distinct token once, matching the retriever" do
    # The retriever's tokenizer uniqs before frequencies are taken, so the
    # scorer has always counted distinct tokens, not occurrences. Storing real
    # counts here would silently change every ranking.
    assert Chunker.term_frequencies("run run run worker") == %{"run" => 1, "worker" => 1}
  end

  test "term_frequencies/1 returns an empty map for a non-binary" do
    assert Chunker.term_frequencies(nil) == %{}
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/mr_eric/rag/chunker_test.exs`
Expected: FAIL — `key :terms not found` and `Chunker.term_frequencies/1 is undefined`.

- [ ] **Step 3: Implement in `lib/mr_eric/rag/chunker.ex`**

Add the token regex next to the other module attributes, under `@default_chunk_overlap`:

```elixir
  @token_regex ~r/[[:alnum:]_]+/u
```

Add the public function immediately after `def chunk_text(_path, _text, _opts), do: []`:

```elixir
  @doc """
  Term frequencies for `text`, in the shape `MrEric.RAG.Retriever` scores from.

  Tokens are downcased, at least two characters long, and **deduplicated
  before counting** -- so every value is `1`. That is not an oversight: the
  retriever's own tokenizer has always ended in `Enum.uniq/1` before
  `Enum.frequencies/1` was applied to it, so the lexical score counts distinct
  query tokens present rather than occurrences. Counting occurrences here
  would change every ranking; whether it should is a retrieval-quality
  question, and Spec E puts those out of scope.
  """
  def term_frequencies(text) when is_binary(text) do
    @token_regex
    |> Regex.scan(String.downcase(text))
    |> List.flatten()
    |> Enum.filter(&(String.length(&1) >= 2))
    |> Enum.uniq()
    |> Enum.frequencies()
  end

  def term_frequencies(_text), do: %{}
```

Replace the private `chunk/4` function with:

```elixir
  defp chunk(path, start_line, lines, content) do
    end_line = start_line + length(lines) - 1

    %{
      id: chunk_id(path, start_line, end_line, content),
      path: path,
      start_line: start_line,
      end_line: end_line,
      content: content,
      terms: term_frequencies(content),
      path_terms: term_frequencies(path)
    }
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/mr_eric/rag/chunker_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: green. Retrieval results are unchanged at this point — `Retriever` still recomputes and ignores the new fields.

- [ ] **Step 6: Commit**

```bash
git add lib/mr_eric/rag/chunker.ex test/mr_eric/rag/chunker_test.exs
git commit -m "perf(rag): precompute chunk term frequencies at index time

Deduplicated before counting, matching the retriever's tokenizer, which
uniqs before frequencies are taken -- so the scorer has always counted
distinct tokens. Retriever still recomputes; that changes next."
```

---

## Task 6: Retriever reads terms and defers the exact bonus

Finishes spec §5e. Measured on this repository's 819-chunk index, precomputed terms alone give 2.5×, deferring the exact bonus alone is a *loss* (0.8×), and the two together give 17.3× against the shipping function (149.03 ms → 8.63 ms).

The deferral is behaviour-preserving: `exact_bonus` fires only when the downcased content contains the whole downcased query, which implies the content contains every query token, which implies a non-zero lexical score. So `exact_bonus > 0 ⟹ lexical_score > 0`, and filtering on lexical score first cannot drop a chunk the bonus could have rescued. The degenerate case — a query whose tokens are all shorter than two characters — already returns `[]` before scoring.

**Files:**
- Modify: `lib/mr_eric/rag/retriever.ex`
- Test: `test/mr_eric/rag/retriever_test.exs` (create)

**Interfaces:**
- Consumes: `MrEric.RAG.Chunker.term_frequencies/1` and the `:terms` / `:path_terms` chunk fields from Task 5.
- Produces: `MrEric.RAG.Retriever.search/3` unchanged in arity, return shape, scores, and ordering.

- [ ] **Step 1: Write the failing test**

Create `test/mr_eric/rag/retriever_test.exs`:

```elixir
defmodule MrEric.RAG.RetrieverTest do
  use ExUnit.Case, async: true

  alias MrEric.RAG.Chunker
  alias MrEric.RAG.Retriever

  defp index(chunks), do: %{chunks: chunks}

  defp chunk(path, content) do
    [c | _] = Chunker.chunk_text(path, content)
    c
  end

  defp legacy(chunk), do: Map.drop(chunk, [:terms, :path_terms])

  defp key(results), do: Enum.map(results, &{&1.path, &1.start_line, &1.score})

  setup do
    chunks = [
      chunk("lib/mr_eric/tools/policy.ex", "approval gate keeps shell commands safe\n"),
      chunk("lib/mr_eric/runs/run_worker.ex", "the worker reaps a terminal run\n"),
      chunk("README.md", "MrEric orchestrates planner draft reviewer synthesizer\n"),
      chunk("docs/notes.md", "approval gate keeps shell commands safe again\n")
    ]

    {:ok, chunks: chunks}
  end

  test "precomputed and recomputed chunks score identically", %{chunks: chunks} do
    for query <- [
          "approval gate",
          "shell commands safe",
          "worker terminal run",
          "planner",
          "nothing matches here",
          "a",
          "MrEric"
        ] do
      precomputed = Retriever.search(index(chunks), query)
      recomputed = Retriever.search(index(Enum.map(chunks, &legacy/1)), query)

      assert key(precomputed) == key(recomputed), "mismatch for #{inspect(query)}"
    end
  end

  test "the exact-phrase bonus still applies", %{chunks: chunks} do
    [top | _] = Retriever.search(index(chunks), "approval gate keeps shell commands safe")

    # 4 distinct query tokens present, +5 for containing the phrase verbatim.
    assert top.score >= 5
    assert top.path == "docs/notes.md" or top.path == "lib/mr_eric/tools/policy.ex"
  end

  test "a query of only one-character tokens returns nothing", %{chunks: chunks} do
    assert Retriever.search(index(chunks), "a b") == []
  end

  test "path tokens are still worth double", %{chunks: chunks} do
    [top | _] = Retriever.search(index(chunks), "run_worker")
    assert top.path == "lib/mr_eric/runs/run_worker.ex"
  end
end
```

- [ ] **Step 2: Run the test to verify it PASSES**

Run: `mix test test/mr_eric/rag/retriever_test.exs`
Expected: PASS.

> This is the one test in the plan that must be green before the change, on purpose. It is a *characterization* test: it pins the scores and ordering the shipping code produces, so that Step 5's rewrite has something it can violate. Today both sides of the identity assertion take the same path — `Retriever` ignores `:terms` and recomputes — so passing here proves only that the harness is wired up. It becomes load-bearing the moment Step 5 lands. If it fails now, stop: something already differs, and that must be understood before touching `Retriever`.
>
> Steps 3 and 4 are the red/green pair for the *new* code path.

- [ ] **Step 3: Add a temporary guard test that fails**

Append to `test/mr_eric/rag/retriever_test.exs`:

```elixir
  test "search does not downcase content for chunks with no lexical match", %{chunks: chunks} do
    # The exact bonus must not be computed for a chunk that scored zero
    # lexically. Proven structurally: a chunk whose content cannot be
    # downcased would crash if the bonus were still evaluated for it.
    poisoned = %{
      id: "poison",
      path: "poison.md",
      start_line: 1,
      end_line: 1,
      content: :not_a_binary,
      terms: %{},
      path_terms: %{}
    }

    assert [_ | _] = Retriever.search(index(chunks ++ [poisoned]), "approval gate")
  end
```

- [ ] **Step 4: Run it to verify it fails**

Run: `mix test test/mr_eric/rag/retriever_test.exs`
Expected: FAIL — `String.downcase/1` raises on `:not_a_binary`, because the bonus is still computed for every chunk.

- [ ] **Step 5: Rewrite `lib/mr_eric/rag/retriever.ex`**

Replace the whole module body below the `@default_top_k` attribute with:

```elixir
  alias MrEric.RAG.Chunker

  def search(index, query, opts \\ [])

  def search(%{chunks: chunks}, query, opts) when is_binary(query) and is_list(chunks) do
    tokens = tokenize(query)
    top_k = Keyword.get(opts, :top_k, Keyword.get(opts, :rag_top_k, @default_top_k))

    if tokens == [] do
      []
    else
      downcased_query = String.downcase(String.trim(query))

      chunks
      |> Enum.map(&Map.put(&1, :score, lexical_score(&1, tokens)))
      |> Enum.filter(&(&1.score > 0))
      |> Enum.map(&Map.put(&1, :score, &1.score + exact_bonus(&1, downcased_query)))
      |> Enum.sort_by(&{-&1.score, &1.path, &1.start_line})
      |> Enum.take(top_k)
    end
  end

  def search(_index, _query, _opts), do: []

  defp lexical_score(chunk, query_tokens) do
    content_terms = terms_for(chunk, :terms, :content)
    path_terms = terms_for(chunk, :path_terms, :path)

    Enum.reduce(query_tokens, 0, fn token, acc ->
      acc + Map.get(content_terms, token, 0) + Map.get(path_terms, token, 0) * 2
    end)
  end

  # `Chunker` attaches these at index time. The recompute branch is for a
  # chunk handed in through `opts[:rag_index]` by a caller holding an older
  # shape; it produces the same value the index would have stored. This is a
  # *performance* fallback, not the "lookup with a default" pattern Spec C-1
  # banned -- no boundary depends on it. Do not add a similar default
  # somewhere one would.
  defp terms_for(chunk, precomputed_key, source_key) do
    case Map.get(chunk, precomputed_key) do
      terms when is_map(terms) -> terms
      _absent -> chunk |> Map.get(source_key, "") |> Chunker.term_frequencies()
    end
  end

  # Only reached for chunks that already scored above zero lexically. That is
  # sound, not an approximation: the bonus fires when the content contains the
  # whole query, which means it contains every query token, which means the
  # lexical score was already non-zero. Computing it for every chunk meant
  # downcasing the entire corpus on every query -- the single largest cost in
  # `search/3`.
  defp exact_bonus(chunk, downcased_query) do
    content = Map.get(chunk, :content, "")

    if is_binary(content) and String.contains?(String.downcase(content), downcased_query) do
      5
    else
      0
    end
  end

  defp tokenize(text) when is_binary(text) do
    ~r/[[:alnum:]_]+/u
    |> Regex.scan(String.downcase(text))
    |> List.flatten()
    |> Enum.filter(&(String.length(&1) >= 2))
    |> Enum.uniq()
  end

  defp tokenize(_text), do: []
end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/mr_eric/rag/retriever_test.exs test/mr_eric/rag/index_test.exs test/mr_eric/rag_test.exs`
Expected: PASS, all of them. The identity test from Step 1 is the important one: it proves the rewrite did not move a single score.

- [ ] **Step 7: Run the full suite and the evals**

Run: `mix test && mix mr_eric.evals`
Expected: suite green; `passed=14 failed=0 skipped=0`.

- [ ] **Step 8: Commit**

```bash
git add lib/mr_eric/rag/retriever.ex test/mr_eric/rag/retriever_test.exs
git commit -m "perf(rag): score from precomputed terms, bonus only candidates

Measured on this repo's 819-chunk index: precomputed terms alone 2.5x,
deferred exact bonus alone 0.8x (a loss), both together 17.3x -- 149.03 ms
to 8.63 ms. Deferral is sound because exact_bonus > 0 implies
lexical_score > 0. Verified score- and order-identical over ten queries."
```

---

## Task 7: The index fingerprint

Starts spec §5a. `Index.discover_paths/2` already calls `File.lstat` on every entry it walks; widening what it carries costs no extra syscalls, and the fingerprint is what lets the cache tell "unchanged" from "stale" without reading a single file.

**Files:**
- Modify: `lib/mr_eric/rag/index.ex`
- Test: `test/mr_eric/rag/index_test.exs`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `MrEric.RAG.Index.fingerprint/1 :: keyword() -> {:ok, integer(), [String.t()]} | {:error, :invalid_workspace}` — the hash, plus the discovered relative paths so `build/1` need not walk again.
  - `MrEric.RAG.Index.build/1` accepts `opts[:paths]` as before; when given, `fingerprint/1` stats exactly those.

- [ ] **Step 1: Write the failing test**

Append to `test/mr_eric/rag/index_test.exs`:

```elixir
  test "fingerprint/1 is stable across calls on an unchanged tree", %{workspace: workspace} do
    assert {:ok, first, paths} = Index.fingerprint(workspace_root: workspace)
    assert {:ok, ^first, ^paths} = Index.fingerprint(workspace_root: workspace)
    assert "README.md" in paths
  end

  test "fingerprint/1 changes when an indexed file's content changes", %{workspace: workspace} do
    assert {:ok, before, _paths} = Index.fingerprint(workspace_root: workspace)

    File.write!(
      Path.join(workspace, "README.md"),
      "MrEric project notes about RAG search, now with more words\n"
    )

    assert {:ok, later, _paths} = Index.fingerprint(workspace_root: workspace)
    refute before == later
  end

  test "fingerprint/1 changes when an eligible file appears", %{workspace: workspace} do
    assert {:ok, before, _paths} = Index.fingerprint(workspace_root: workspace)

    File.write!(Path.join(workspace, "NOTES.md"), "a brand new note about approvals\n")

    assert {:ok, later, new_paths} = Index.fingerprint(workspace_root: workspace)
    refute before == later
    assert "NOTES.md" in new_paths
  end

  test "fingerprint/1 ignores files the index would not read", %{workspace: workspace} do
    assert {:ok, before, _paths} = Index.fingerprint(workspace_root: workspace)

    File.write!(Path.join(workspace, ".env"), "OPENAI_API_KEY=sk-changed-entirely")

    assert {:ok, later, _paths} = Index.fingerprint(workspace_root: workspace)
    assert before == later
  end

  test "fingerprint/1 honours an explicit path list", %{workspace: workspace} do
    opts = [workspace_root: workspace, paths: ["README.md"]]

    assert {:ok, before, ["README.md"]} = Index.fingerprint(opts)

    File.write!(Path.join(workspace, "README.md"), "different content entirely\n")

    assert {:ok, later, ["README.md"]} = Index.fingerprint(opts)
    refute before == later
  end

  test "fingerprint/1 reports an invalid workspace like build/1 does" do
    assert {:error, :invalid_workspace} =
             Index.fingerprint(workspace_root: "/nonexistent/mr-eric-workspace")
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/mr_eric/rag/index_test.exs`
Expected: FAIL — `MrEric.RAG.Index.fingerprint/1 is undefined`.

- [ ] **Step 3: Implement in `lib/mr_eric/rag/index.ex`**

Replace `discover_paths/2` and `discover_dir/8` with versions that carry stat data, and add `fingerprint/1`. Insert `fingerprint/1` immediately after `def build(opts \\ []) do … end`:

```elixir
  @doc """
  A cheap identity for what `build/1` would read, plus the paths it found.

  The walk is `File.lstat` only -- the same lstat `discover_paths/2` already
  performs -- so this costs no extra syscalls. Reading, chunking and
  tokenizing the files is the expensive half, and it is what a matching
  fingerprint lets the cache skip.

  `size` is part of the entry as well as `mtime`: mtime granularity is one
  second on some filesystems, and size catches most same-second edits. A
  same-second, same-size edit can still slip through; the alternative is
  hashing every file, which costs exactly what the cache exists to save.
  """
  def fingerprint(opts \\ []) do
    workspace = Policy.workspace_root(opts)

    if File.dir?(workspace) do
      entries =
        case Keyword.get(opts, :paths) || Keyword.get(opts, :rag_paths) do
          nil -> discover_entries(workspace, opts)
          paths -> Enum.map(paths, &stat_entry(workspace, to_string(&1)))
        end

      sorted = Enum.sort(entries)
      {:ok, :erlang.phash2(sorted), Enum.map(sorted, fn {path, _mtime, _size} -> path end)}
    else
      {:error, :invalid_workspace}
    end
  end

  defp stat_entry(workspace, relative_path) do
    case File.lstat(Path.join(workspace, relative_path)) do
      {:ok, %File.Stat{mtime: mtime, size: size}} -> {relative_path, mtime, size}
      {:error, reason} -> {relative_path, reason, -1}
    end
  end
```

Change `discover_paths/2` to project from the entry walk:

```elixir
  defp discover_paths(workspace, opts) do
    workspace
    |> discover_entries(opts)
    |> Enum.map(fn {path, _mtime, _size} -> path end)
  end

  defp discover_entries(workspace, opts) do
    extensions = Keyword.get(opts, :include_extensions, @default_extensions)
    allow_secret = Keyword.get(opts, :allow_secret_paths, false)

    base_dirs =
      if allow_secret,
        do: @default_ignored_dirs -- @secret_dirs,
        else: @default_ignored_dirs

    ignored_dirs =
      (base_dirs ++ Keyword.get(opts, :extra_ignored_dirs, []))
      |> MapSet.new()

    ignored_files = @default_ignored_files ++ Keyword.get(opts, :extra_ignored_files, [])
    ignored_extensions = MapSet.new(@default_ignored_extensions)

    workspace
    |> discover_dir("", extensions, ignored_dirs, ignored_files,
                    ignored_extensions, allow_secret, [])
    |> Enum.reverse()
  end
```

In `discover_dir/8`, change the regular-file branch's final `true ->` clause so it accumulates the stat too. The branch currently reads:

```elixir
            {:ok, %File.Stat{type: :regular}} ->
              cond do
```

Change that head to bind the stat fields:

```elixir
            {:ok, %File.Stat{type: :regular, mtime: mtime, size: size}} ->
              cond do
```

and change that `cond`'s last clause from:

```elixir
                true -> [relative_path | acc]
```

to:

```elixir
                true -> [{relative_path, mtime, size} | acc]
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/mr_eric/rag/index_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: green. `build/1`'s behaviour is unchanged — it still receives a plain path list from `discover_paths/2`.

- [ ] **Step 6: Commit**

```bash
git add lib/mr_eric/rag/index.ex test/mr_eric/rag/index_test.exs
git commit -m "feat(rag): add Index.fingerprint/1 from the existing lstat walk

Carries {path, mtime, size} through the walk discover_paths/2 already
performs, so identifying an unchanged tree costs no extra syscalls."
```

---

## Task 8: `MrEric.RAG.Cache`

Implements spec §5b and §5c. Read the spec's measurement table before setting any number: on this repository the index is 5.32 MiB for 819 chunks — 6,811 B per chunk — and 75 % of that is the term maps. Bounding by chunk count is not a memory bound, the same way `max_trace_entries` was not one in Spec D.

**Files:**
- Create: `lib/mr_eric/rag/cache.ex`
- Modify: `lib/mr_eric/application.ex`
- Test: `test/mr_eric/rag/cache_test.exs` (create)

**Interfaces:**
- Consumes: nothing from earlier tasks (the cache stores whatever map it is given).
- Produces:
  - `MrEric.RAG.Cache.key/1 :: keyword() -> tuple()`
  - `MrEric.RAG.Cache.fetch/2 :: (tuple(), integer()) -> {:ok, map()} | :stale | :miss`
  - `MrEric.RAG.Cache.put/3 :: (tuple(), integer(), map()) -> :ok`
  - `MrEric.RAG.Cache.flush/0 :: [] -> :ok`
  - `MrEric.RAG.Cache.index_bytes/1 :: map() -> non_neg_integer()`
  - `MrEric.RAG.Cache.fetch!/1 :: atom() -> integer()` — raises for an unknown key.

- [ ] **Step 1: Write the failing test**

Create `test/mr_eric/rag/cache_test.exs`:

```elixir
defmodule MrEric.RAG.CacheTest do
  use ExUnit.Case, async: false

  alias MrEric.RAG.Cache

  setup do
    Cache.flush()
    on_exit(&Cache.flush/0)
    :ok
  end

  defp index(chunks), do: %{chunks: chunks, workspace_root: "/w", errors: [], file_count: 1}

  defp chunk(content, terms) do
    %{
      id: "c",
      path: "a.md",
      start_line: 1,
      end_line: 1,
      content: content,
      terms: terms,
      path_terms: %{}
    }
  end

  test "fetch/2 misses on an unknown key" do
    assert Cache.fetch({:nothing, :here}, 1) == :miss
  end

  test "put/3 then fetch/2 with the same fingerprint hits" do
    key = Cache.key(workspace_root: "/w")
    idx = index([chunk("hello", %{"hello" => 1})])

    assert :ok = Cache.put(key, 42, idx)
    assert {:ok, ^idx} = Cache.fetch(key, 42)
  end

  test "fetch/2 reports :stale when the fingerprint moved" do
    key = Cache.key(workspace_root: "/w")

    assert :ok = Cache.put(key, 42, index([chunk("hello", %{"hello" => 1})]))
    assert Cache.fetch(key, 43) == :stale
  end

  test "allow_secret_paths is part of the key" do
    safe = Cache.key(workspace_root: "/w", allow_secret_paths: false)
    unsafe = Cache.key(workspace_root: "/w", allow_secret_paths: true)

    refute safe == unsafe

    assert :ok = Cache.put(unsafe, 1, index([chunk("SECRET", %{"secret" => 1})]))
    assert Cache.fetch(safe, 1) == :miss
  end

  test "every content-affecting option changes the key" do
    base = [workspace_root: "/w"]
    base_key = Cache.key(base)

    variants = [
      [include_extensions: ~w(.ex)],
      [max_file_bytes: 1_000],
      [chunk_size: 400],
      [chunk_overlap: 40],
      [extra_ignored_dirs: ["vendor"]],
      [extra_ignored_files: [~r/^ignore\.md$/]],
      [paths: ["README.md"]]
    ]

    for variant <- variants do
      refute Cache.key(base ++ variant) == base_key, "#{inspect(variant)} did not change the key"
    end
  end

  test "regex options are normalized rather than inspected" do
    a = Cache.key(workspace_root: "/w", extra_ignored_files: [~r/^x$/])
    b = Cache.key(workspace_root: "/w", extra_ignored_files: [~r/^x$/])
    c = Cache.key(workspace_root: "/w", extra_ignored_files: [~r/^x$/i])

    assert a == b
    refute a == c
  end

  test "index_bytes/1 counts content and term-key bytes plus per-entry overhead" do
    idx = index([chunk("abcd", %{"ab" => 1, "cde" => 1})])

    # 4 content bytes + (2 + 48) + (3 + 48) + 200 per-chunk = 305
    assert Cache.index_bytes(idx) == 305
  end

  test "an index over max_cached_index_bytes is not stored" do
    key = Cache.key(workspace_root: "/big")
    limit = Cache.fetch!(:max_cached_index_bytes)
    huge = index([chunk(String.duplicate("x", limit + 1), %{})])

    assert :ok = Cache.put(key, 1, huge)
    assert Cache.fetch(key, 1) == :miss
  end

  test "max_cached_indexes evicts the least recently read entry" do
    limit = Cache.fetch!(:max_cached_indexes)
    keys = for i <- 1..(limit + 1), do: Cache.key(workspace_root: "/w#{i}")
    small = index([chunk("x", %{})])

    [first | rest] = keys
    Enum.each(keys, fn key -> :ok = Cache.put(key, 1, small) end)

    assert Cache.fetch(first, 1) == :miss
    assert Enum.all?(Enum.take(rest, -limit), &match?({:ok, _}, Cache.fetch(&1, 1)))
  end

  test "fetch!/1 raises for an unknown limit key" do
    assert_raise FunctionClauseError, fn -> Cache.fetch!(:no_such_limit) end
  end

  test "the documented defaults are the ones in use" do
    assert Cache.fetch!(:max_cached_index_bytes) == 24_000_000
    assert Cache.fetch!(:max_cached_total_bytes) == 48_000_000
    assert Cache.fetch!(:max_cached_indexes) == 4
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/mr_eric/rag/cache_test.exs`
Expected: FAIL — `MrEric.RAG.Cache is not available`.

- [ ] **Step 3: Create `lib/mr_eric/rag/cache.ex`**

```elixir
defmodule MrEric.RAG.Cache do
  @moduledoc """
  Bounded in-memory cache of built RAG indexes (Spec E).

  A `GenServer` owns an ETS table, so the cache dies with the process and
  nothing outlives a restart. Reads run in the calling process as a direct
  `:ets.lookup/2`; only `put/3` is serialized, because only `put/3` applies
  the bounds.

  **Building happens in the caller, never here.** `MrEric.RAG.Index.build/1`
  reads an unbounded number of files, and Spec D established what happens when
  work like that runs inside a process everything else waits on. The cost is
  that two simultaneous misses on the same key both build; they produce the
  same index, and that is cheaper than serializing every build.

  ## Limits

  `@defaults` is the single source of truth. Configuration is override-only:

      config :mr_eric, :rag_cache, max_cached_total_bytes: 96_000_000

  `fetch!/1` has no catch-all clause and no default parameter: an unknown key
  raises at the call site rather than returning a plausible number.

  The bound is **bytes, not chunks**. A chunk's `content` is capped by
  `chunk_size`, but the `:terms` map is not capped by anything the cache
  controls, and it is the larger half. Measured on the MrEric repository
  itself (2026-08-28): 148 files, 819 chunks, 1.16 MiB of content, 0.17 MiB
  of chunk structures, 3.99 MiB of term maps -- 5.32 MiB total, 6,811 B per
  chunk. A `max_cached_chunks: 20_000` bound, which is what this module was
  first drafted with, would have permitted ~136 MiB per index. Spec D reached
  the same conclusion about the trace and `CLAUDE.md` records it: bounded by
  size, not only by entry count.
  """

  use GenServer

  @table __MODULE__

  @defaults %{
    # Largest single index kept. ~4.5x the MrEric repository's own index, so a
    # project several times larger still caches. Beyond this the index is
    # returned to the caller and simply not stored.
    max_cached_index_bytes: 24_000_000,
    # The real ceiling across every cached index: two full-size ones, or ~9 of
    # this repository. For scale, the run side budgets ~8 MiB
    # (max_trace_payload_chars x max_trace_entries x max_concurrent_runs).
    max_cached_total_bytes: 48_000_000,
    # Key-count guard, so many tiny workspaces cannot grow the table without
    # limit. Not a memory bound -- that is what the two byte limits are.
    max_cached_indexes: 4
  }

  # Measured map-entry overhead: 75,719 term entries occupied 4,183,256 B of
  # heap, of which 481,435 B were key bytes, leaving 48.8 B per entry. The flat
  # per-chunk figure covers the chunk map itself. The model predicts 5.28 MiB
  # against a measured 5.32 MiB -- within 1.6 %.
  @term_entry_overhead_bytes 48
  @chunk_overhead_bytes 200

  @doc "The built-in defaults, keyed by limit name."
  def defaults, do: @defaults

  @doc """
  Returns the configured value for `key`, or its built-in default.

  Raises `FunctionClauseError` for an unsupported key.
  """
  def fetch!(key) when is_map_key(@defaults, key) do
    :mr_eric
    |> Application.get_env(:rag_cache, [])
    |> Keyword.get(key, Map.fetch!(@defaults, key))
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The cache key for a set of index options.

  Every option that can change the *content* of an index is here.
  `allow_secret_paths` most of all: it decides whether `config/`,
  `priv/cert/`, `priv/secrets/` and `Policy.secret_path?/1` matches are walked
  at all, so a key that omitted it would let an index built for a caller that
  asked for secrets be served to one that asked for the safe index. That is
  the only way a cache can reopen the boundary Spec A closed. Key construction
  lives here and nowhere else.
  """
  def key(opts) do
    {
      MrEric.Tools.Policy.workspace_root(opts),
      Keyword.get(opts, :allow_secret_paths, false),
      Keyword.get(opts, :include_extensions),
      Keyword.get(opts, :extra_ignored_dirs, []),
      normalize_regexes(Keyword.get(opts, :extra_ignored_files, [])),
      Keyword.get(opts, :max_file_bytes),
      Keyword.get(opts, :chunk_size, Keyword.get(opts, :rag_chunk_size)),
      Keyword.get(opts, :chunk_overlap, Keyword.get(opts, :rag_chunk_overlap)),
      Keyword.get(opts, :paths) || Keyword.get(opts, :rag_paths)
    }
  end

  @doc "Looks the key up, in the calling process. `:stale` means the fingerprint moved."
  def fetch(key, fingerprint) do
    case :ets.lookup(@table, key) do
      [{^key, ^fingerprint, index}] ->
        GenServer.cast(__MODULE__, {:touch, key})
        {:ok, index}

      [{^key, _other_fingerprint, _index}] ->
        :stale

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc "Stores `index`, applying the bounds. Oversized indexes are silently not stored."
  def put(key, fingerprint, index) do
    GenServer.call(__MODULE__, {:put, key, fingerprint, index})
  end

  @doc "Empties the cache. For tests."
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @doc """
  The modelled resident size of `index`, in bytes.

  Content bytes, plus each term key's bytes and the measured per-entry map
  overhead, plus a flat per-chunk allowance for the chunk map itself.
  """
  def index_bytes(%{chunks: chunks}) when is_list(chunks) do
    Enum.reduce(chunks, 0, fn chunk, acc ->
      acc + chunk_bytes(chunk)
    end)
  end

  def index_bytes(_index), do: 0

  defp chunk_bytes(chunk) do
    content = Map.get(chunk, :content, "")
    content_bytes = if is_binary(content), do: byte_size(content), else: 0

    content_bytes + term_bytes(Map.get(chunk, :terms)) +
      term_bytes(Map.get(chunk, :path_terms)) + @chunk_overhead_bytes
  end

  defp term_bytes(terms) when is_map(terms) do
    Enum.reduce(terms, 0, fn {term, _count}, acc ->
      acc + byte_size(term) + @term_entry_overhead_bytes
    end)
  end

  defp term_bytes(_terms), do: 0

  defp normalize_regexes(patterns) when is_list(patterns) do
    Enum.map(patterns, fn
      %Regex{} = regex -> {Regex.source(regex), Regex.opts(regex)}
      other -> other
    end)
  end

  defp normalize_regexes(other), do: other

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    {:ok, %{table: table, reads: %{}, counter: 0}}
  end

  @impl true
  def handle_call({:put, key, fingerprint, index}, _from, state) do
    bytes = index_bytes(index)

    if bytes > fetch!(:max_cached_index_bytes) do
      {:reply, :ok, state}
    else
      :ets.insert(@table, {key, fingerprint, index})
      state = touch(state, key)
      {:reply, :ok, evict(state)}
    end
  end

  def handle_call(:flush, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | reads: %{}, counter: 0}}
  end

  @impl true
  def handle_cast({:touch, key}, state) do
    {:noreply, touch(state, key)}
  end

  defp touch(state, key) do
    counter = state.counter + 1
    %{state | counter: counter, reads: Map.put(state.reads, key, counter)}
  end

  # Least-recently-read first, until both the count and the total byte budget
  # fit. Reading the whole table to total it is fine: `max_cached_indexes` is
  # a single-digit number.
  defp evict(state) do
    entries =
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {key, _fingerprint, index} ->
        {Map.get(state.reads, key, 0), key, index_bytes(index)}
      end)
      |> Enum.sort()

    max_indexes = fetch!(:max_cached_indexes)
    max_total = fetch!(:max_cached_total_bytes)

    {kept_reads, _count, _bytes} =
      entries
      |> Enum.reverse()
      |> Enum.reduce({state.reads, 0, 0}, fn {_read, key, bytes}, {reads, count, total} ->
        if count + 1 > max_indexes or total + bytes > max_total do
          :ets.delete(@table, key)
          {Map.delete(reads, key), count, total}
        else
          {reads, count + 1, total + bytes}
        end
      end)

    %{state | reads: kept_reads}
  end
end
```

- [ ] **Step 4: Start the cache in `lib/mr_eric/application.ex`**

In the `children` list, add `MrEric.RAG.Cache` after `MrEric.Runs.RunSupervisor`:

```elixir
      {Registry, keys: :unique, name: MrEric.Runs.Registry},
      MrEric.Runs.RunSupervisor,
      MrEric.RAG.Cache,
      MrEricWeb.Endpoint
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/mr_eric/rag/cache_test.exs`
Expected: PASS. If `index_bytes/1` returns something other than 305 in that unit test, recheck the arithmetic in the test comment before changing the constants — the constants are measured values, documented in the moduledoc.

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: green. Nothing calls the cache yet.

- [ ] **Step 7: Commit**

```bash
git add lib/mr_eric/rag/cache.ex lib/mr_eric/application.ex test/mr_eric/rag/cache_test.exs
git commit -m "feat(rag): add a byte-bounded index cache

ETS owned by a GenServer; reads run in the caller, only put/3 is
serialized, and building stays in the caller. Bounded by modelled bytes
rather than chunk count -- measured, the term maps are 75% of an index and
a 20k-chunk bound would have permitted ~136 MiB each. allow_secret_paths
is part of the key, which is the only thing keeping a cache from reopening
Spec A's boundary."
```

---

## Task 9: `RAG.context_for/2` uses the cache

Implements spec §5d.

**Files:**
- Modify: `lib/mr_eric/rag.ex`
- Test: `test/mr_eric/rag_test.exs`

**Interfaces:**
- Consumes: `Index.fingerprint/1` (Task 7), `Cache.key/1` / `fetch/2` / `put/3` (Task 8).
- Produces: `MrEric.RAG.context_for/2` unchanged in arity and return shape.

- [ ] **Step 1: Write the failing test**

Append to `test/mr_eric/rag_test.exs`:

```elixir
  test "a second lookup on an unchanged workspace does not rebuild", %{workspace: workspace} do
    MrEric.RAG.Cache.flush()

    opts = [workspace_root: workspace]

    assert {:ok, first} = RAG.context_for("How does shell approval work?", opts)
    assert {:ok, _cached} = RAG.context_for("How does shell approval work?", opts)

    key = MrEric.RAG.Cache.key(opts)
    assert {:ok, fingerprint, _paths} = MrEric.RAG.Index.fingerprint(opts)
    assert {:ok, index} = MrEric.RAG.Cache.fetch(key, fingerprint)
    assert is_list(index.chunks)

    assert {:ok, ^first} = RAG.context_for("How does shell approval work?", opts)
  end

  test "editing an indexed file invalidates the cached index", %{workspace: workspace} do
    MrEric.RAG.Cache.flush()

    opts = [workspace_root: workspace]
    assert {:ok, _first} = RAG.context_for("shell approval", opts)
    assert {:ok, before_fingerprint, _} = MrEric.RAG.Index.fingerprint(opts)

    File.write!(
      Path.join(workspace, "lib/mr_eric/tools/policy.ex"),
      "shell commands always require approval and now mention caching\n"
    )

    assert {:ok, later_fingerprint, _} = MrEric.RAG.Index.fingerprint(opts)
    refute before_fingerprint == later_fingerprint

    assert {:ok, context} = RAG.context_for("caching", opts)
    assert context =~ "caching"
  end

  test "a secret-inclusive index is never served to a safe caller", %{workspace: workspace} do
    MrEric.RAG.Cache.flush()

    # `.env` is excluded by extension *and* by filename whatever
    # allow_secret_paths says, so it cannot tell the two indexes apart. A file
    # under `config/` can: that directory is in @default_ignored_dirs and is
    # removed from the ignore set only when allow_secret_paths is true.
    File.mkdir_p!(Path.join(workspace, "config"))

    File.write!(
      Path.join(workspace, "config/dev.secret.exs"),
      ~s(import Config\nconfig :mr_eric, token: "phase-e-cache-key-canary"\n)
    )

    permissive = [workspace_root: workspace, allow_secret_paths: true]
    safe = [workspace_root: workspace]

    # Warm the cache with the permissive index first, and prove it really does
    # contain the canary -- otherwise the assertion below passes for the wrong
    # reason.
    assert {:ok, permissive_context} = RAG.context_for("cache key canary", permissive)
    assert permissive_context =~ "phase-e-cache-key-canary"

    assert {:ok, safe_context} = RAG.context_for("cache key canary", safe)
    refute safe_context =~ "phase-e-cache-key-canary"

    # And the two live under different keys rather than one having evicted the
    # other.
    refute MrEric.RAG.Cache.key(permissive) == MrEric.RAG.Cache.key(safe)
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/mr_eric/rag_test.exs`
Expected: the first test FAILS — nothing was put in the cache.

- [ ] **Step 3: Rewrite `index_for/1` in `lib/mr_eric/rag.ex`**

Add the aliases at the top of the module, next to the existing ones:

```elixir
  alias MrEric.RAG.Cache
```

Replace `index_for/1` with:

```elixir
  # `opts[:rag_index]` stays the caller's escape hatch and never touches the
  # cache. Otherwise: identify the tree with an lstat-only walk, use the cached
  # index if it matches, and build in this process on a miss or a mismatch --
  # never inside the cache GenServer.
  defp index_for(opts) do
    case Keyword.get(opts, :rag_index) do
      %{chunks: chunks} = index when is_list(chunks) ->
        {:ok, index}

      _none ->
        case Index.fingerprint(opts) do
          {:ok, fingerprint, paths} -> cached_index(opts, fingerprint, paths)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp cached_index(opts, fingerprint, paths) do
    key = Cache.key(opts)

    case Cache.fetch(key, fingerprint) do
      {:ok, index} ->
        {:ok, index}

      _stale_or_miss ->
        # Hand `build/1` the paths the fingerprint walk already found, so the
        # tree is walked once per `context_for/2` rather than twice.
        with {:ok, index} <- Index.build(Keyword.put(opts, :paths, paths)) do
          Cache.put(key, fingerprint, index)
          {:ok, index}
        end
    end
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/mr_eric/rag_test.exs test/mr_eric/rag/index_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full suite and the evals**

Run: `mix test && mix mr_eric.evals`
Expected: suite green; `passed=14 failed=0 skipped=0`.

- [ ] **Step 6: Commit**

```bash
git add lib/mr_eric/rag.ex test/mr_eric/rag_test.exs
git commit -m "perf(rag): serve an unchanged workspace from the index cache

fingerprint (lstat only) decides; build happens in the caller on a miss.
opts[:rag_index] still bypasses the cache entirely."
```

---

## Task 10: `:rag_failed` joins the event vocabulary

Implements the first half of spec §6. `:rag_failed` already exists in `Errors.classifications/0` and in `Case`'s `@classifications`, and nothing has ever emitted it.

**Files:**
- Modify: `lib/mr_eric/runs/events.ex`
- Modify: `lib/mr_eric/runs/trace.ex`
- Test: `test/mr_eric/runs/rag_failed_event_test.exs` (create)

**Interfaces:**
- Consumes: `MrEric.Errors.classify/1`.
- Produces: `:rag_failed` is a member of `MrEric.Runs.Events.names/0`, is sanitized like the other error-carrying events, and carries `:error_class` into the trace entry.

- [ ] **Step 1: Write the failing test**

Create `test/mr_eric/runs/rag_failed_event_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/mr_eric/runs/rag_failed_event_test.exs`
Expected: FAIL — `:rag_failed` is not in `Events.names/0`, so `normalize_event/2` has no matching clause.

- [ ] **Step 3: Add the event in `lib/mr_eric/runs/events.ex`**

Add `:rag_failed` to `@event_names`, after `:tool_rejected`:

```elixir
    :tool_denied,
    :tool_rejected,
    # RAG failure never fails a run -- the planner proceeds with empty context
    # -- but it used to say nothing at all, so "RAG broke" and "RAG found
    # nothing" were the same observation.
    :rag_failed
  ]
```

Add `:rag_failed` to the sanitized set so the classification is taken here, while the raw reason still exists, rather than being re-derived from an English sentence downstream:

```elixir
  defp sanitize_payload(payload, event)
       when event in [
              :stage_failed,
              :run_failed,
              :tool_failed,
              :tool_denied,
              :tool_rejected,
              :rag_failed
            ] do
```

`public_error(:rag_failed)` already exists — "Project context lookup failed." — so no new message is needed.

- [ ] **Step 4: Carry the classification into the trace in `lib/mr_eric/runs/trace.ex`**

Add `:rag_failed` to the `error_classification/2` event list:

```elixir
  defp error_classification(event, payload)
       when event in [
              :run_failed,
              :stage_failed,
              :tool_failed,
              :tool_denied,
              :tool_rejected,
              :rag_failed
            ] do
    classify(payload, payload)
  end
```

Do **not** add an `update_from_event/4` clause for `:rag_failed`. That function sets the *trace-level* `error_classification`, which `summary/1` exposes and which answers "how did this run fail". A run that completed with degraded context did not fail, so the existing catch-all — leaving it `nil` — is the correct behaviour, and the second test above pins it.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/mr_eric/runs/rag_failed_event_test.exs test/mr_eric/runs/events_test.exs test/mr_eric/runs/trace_test.exs`
Expected: PASS.

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: green. If `run_test.exs` has a test asserting every event name is handled by `Run.do_apply_event/3`, it should still pass — the module's final catch-all clause returns the run unchanged, which is correct for `:rag_failed`: the run's status must not move.

- [ ] **Step 7: Commit**

```bash
git add lib/mr_eric/runs/events.ex lib/mr_eric/runs/trace.ex test/mr_eric/runs/rag_failed_event_test.exs
git commit -m "feat(runs): add the :rag_failed event

:rag_failed was already in Errors.classifications/0 and in the eval case
vocabulary, and nothing ever emitted it. Sanitized and classified at
normalize_event/2 like every other error-carrying event."
```

---

## Task 11: The orchestrator emits `:rag_failed`

Finishes spec §6. `do_rag_context_for/2` collapses every failure to `""` through a bare `rescue`/`catch`. Not failing the run is correct and stays; saying nothing is what changes.

**Files:**
- Modify: `lib/mr_eric/orchestrator.ex`
- Test: `test/mr_eric/orchestrator_test.exs`

**Interfaces:**
- Consumes: `:rag_failed` from Task 10.
- Produces: `stream/3` sends `{:rag_failed, %{run_id: …, error: <sanitized>, error_class: :rag_failed}}` to its pid when the RAG module fails. `run/2` (no pid) is unchanged and emits nothing.

- [ ] **Step 1: Write the failing test**

Append to `test/mr_eric/orchestrator_test.exs`, inside the existing module:

```elixir
  defmodule RaisingRAGForTest do
    @moduledoc false
    def context_for(_task, _opts), do: raise("rag exploded with sk-secretvalue123456789")
  end

  defmodule EmptyRAGForTest do
    @moduledoc false
    def context_for(_task, _opts), do: {:ok, ""}
  end

  test "stream/3 emits :rag_failed and still completes the run" do
    opts = [
      provider_module: MrEric.LLM.FakeProvider,
      provider: :fake,
      model: "fake-model",
      scenario: "simple_planning",
      rag_module: RaisingRAGForTest,
      run_id: "rag-fail-1"
    ]

    Orchestrator.stream("summarize the project", self(), opts)

    assert_received {:rag_failed, payload}
    assert payload.run_id == "rag-fail-1"
    assert payload.error_class == :rag_failed

    refute_received {:run_failed, _}
  end

  test "a RAG module that legitimately returns empty context emits nothing" do
    opts = [
      provider_module: MrEric.LLM.FakeProvider,
      provider: :fake,
      model: "fake-model",
      scenario: "simple_planning",
      rag_module: EmptyRAGForTest,
      run_id: "rag-empty-1"
    ]

    Orchestrator.stream("summarize the project", self(), opts)

    refute_received {:rag_failed, _}
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/mr_eric/orchestrator_test.exs`
Expected: the first new test FAILS at `assert_received {:rag_failed, payload}` — no such message.

- [ ] **Step 3: Thread the pid through the RAG helpers in `lib/mr_eric/orchestrator.ex`**

`rag_context_for/2` has two callers: `run_planner/2` (no pid, from `run/2`) and `stream_planner/4`. Give it a pid parameter that may be `nil`.

In `run_planner/2`, change:

```elixir
    rag_context = rag_context_for(task, opts)
```

to:

```elixir
    rag_context = rag_context_for(task, nil, opts)
```

In `stream_planner/4`, which already has `pid` in scope, change:

```elixir
    rag_context = rag_context_for(task, opts)
```

to:

```elixir
    rag_context = rag_context_for(task, pid, opts)
```

Replace `rag_context_for/2` and `do_rag_context_for/2` with:

```elixir
  defp rag_context_for(task, pid, opts) do
    cond do
      Keyword.get(opts, :rag_enabled, Keyword.get(opts, :rag_enabled?, true)) == false ->
        ""

      is_binary(Keyword.get(opts, :rag_context)) ->
        Keyword.get(opts, :rag_context) |> String.trim() |> limit_text(max_context_chars(opts))

      true ->
        do_rag_context_for(task, pid, opts)
    end
  end

  # A RAG failure must never fail a run: the planner proceeds with empty
  # context, exactly as before. What changes is that it no longer happens in
  # silence -- "RAG raised" and "RAG found nothing" used to be the same
  # observation, which is why the golden case for the first could pass on the
  # second.
  defp do_rag_context_for(task, pid, opts) do
    rag_module = Keyword.get(opts, :rag_module, RAG)

    case rag_module.context_for(task, opts) do
      {:ok, context} when is_binary(context) ->
        context |> String.trim() |> limit_text(max_context_chars(opts))

      context when is_binary(context) ->
        context |> String.trim() |> limit_text(max_context_chars(opts))

      other ->
        emit_rag_failed(pid, other, opts)
        ""
    end
  rescue
    error ->
      emit_rag_failed(pid, Exception.message(error), opts)
      ""
  catch
    _kind, reason ->
      emit_rag_failed(pid, reason, opts)
      ""
  end

  defp emit_rag_failed(nil, _reason, _opts), do: :ok

  defp emit_rag_failed(pid, reason, opts) when is_pid(pid) do
    # `send_event/4` hands the payload to `RunWorker`, which normalizes it
    # through `Events.normalize_event/2` -- that is where the raw reason is
    # redacted and the classification is taken. Nothing raw leaves here.
    send_event(pid, :rag_failed, %{error: reason, stage: :planner}, opts)
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/mr_eric/orchestrator_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full suite and the evals**

Run: `mix test && mix mr_eric.evals`
Expected: suite green; `passed=14 failed=0 skipped=0`. The `rag_failure_does_not_break_run` case still passes — it does not yet assert the new event; Task 12 makes it.

- [ ] **Step 6: Commit**

```bash
git add lib/mr_eric/orchestrator.ex test/mr_eric/orchestrator_test.exs
git commit -m "feat(orchestrator): emit :rag_failed instead of failing silently

The bare rescue/catch collapsed every RAG failure to empty context with no
record. The run still completes on empty context; it just says so now."
```

---

## Task 12: The golden case for RAG failure asserts the failure

**Files:**
- Modify: `lib/mr_eric/evals/case.ex` (the `@events` table)
- Modify: `priv/evals/phase9_golden_cases.json`

**Interfaces:**
- Consumes: `:rag_failed` from Tasks 10 and 11.
- Produces: `"rag_failed"` is a legal value in `expected_events` and `forbidden_events`.

- [ ] **Step 1: Add `"rag_failed"` to the event table in `lib/mr_eric/evals/case.ex`**

In `@events`, after `"tool_rejected" => :tool_rejected`:

```elixir
    "tool_rejected" => :tool_rejected,
    "rag_failed" => :rag_failed
  }
```

- [ ] **Step 2: Tighten the golden case in `priv/evals/phase9_golden_cases.json`**

Replace the `rag_failure_does_not_break_run` object with:

```json
  {
    "name": "rag_failure_does_not_break_run",
    "task": "Continue safely if basic RAG context lookup fails",
    "scenario": "rag_failure_does_not_break_run",
    "requires": ["rag"],
    "expected_status": "completed",
    "expected_final_contains": ["rag failure"],
    "expected_events": ["rag_failed", "run_completed"],
    "forbidden_events": ["run_failed"],
    "expected_no_secret_leak": true
  },
```

- [ ] **Step 3: Run the evals to verify the case now proves what it claims**

Run: `mix mr_eric.evals --case rag_failure_does_not_break_run`
Expected: `rag_failure_does_not_break_run: passed`. If it fails on `:expected_events`, the orchestrator's emission from Task 11 is not reaching the trace — debug there, not by weakening the case.

- [ ] **Step 4: Run the full suite and all evals**

Run: `mix test && mix mr_eric.evals`
Expected: suite green; `passed=14 failed=0 skipped=0`.

- [ ] **Step 5: Commit**

```bash
git add lib/mr_eric/evals/case.ex priv/evals/phase9_golden_cases.json
git commit -m "test(evals): make the RAG-failure case assert the failure

It passed whether or not the RAG module ever raised. Now it requires the
rag_failed event and forbids run_failed."
```

---

## Task 13: The `rag_default_index` golden case

Implements spec §7 — the case Spec A wrote and could not wire up. Both existing RAG cases bypass the real index; `Index.build/1`, which implements Spec A's secret-path exclusion, is exercised by unit tests and by no golden case at all.

**Files:**
- Modify: `lib/mr_eric/evals/runner.ex`
- Modify: `lib/mr_eric/llm/fake_provider.ex`
- Modify: `priv/evals/phase9_golden_cases.json`

**Interfaces:**
- Consumes: the `plan:` field in `actual` from Task 4; `Chunker`/`Index`/`Retriever` from Tasks 5–7; the cache from Tasks 8–9.
- Produces: a golden case named `rag_default_index`, and a `FakeProvider` scenario of the same name.

- [ ] **Step 1: Seed the workspace in `lib/mr_eric/evals/runner.ex`**

Replace `setup_workspace/1` with a scenario-aware version:

```elixir
  defp setup_workspace(eval_case) do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "mr-eric-eval-#{eval_case.name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "note.txt"), "old\n")
    seed_scenario_files(workspace, eval_case.scenario)
    System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)
    System.cmd("git", ["add", "note.txt"], cd: workspace, stderr_to_stdout: true)
    workspace
  end

  # `rag_default_index` drives the real `MrEric.RAG.Index.build/1`, so the
  # workspace has to contain both something the index must find and everything
  # Spec A says it must not. Every secret here is a fixed dummy value shaped to
  # match `SecretChecker`'s patterns -- if any of them reaches the planner
  # prompt, the case fails on `:secret_leak` rather than passing quietly.
  defp seed_scenario_files(workspace, "rag_default_index") do
    File.write!(
      Path.join(workspace, "README.md"),
      """
      MrEric notes: phase9-default-index-marker
      The planner should see this file and nothing under config or priv/cert.
      """
    )

    File.write!(
      Path.join(workspace, ".env"),
      "OPENAI_API_KEY=sk-phase9dummysecret123456789\n"
    )

    File.mkdir_p!(Path.join(workspace, "config"))

    File.write!(
      Path.join(workspace, "config/dev.secret.exs"),
      ~s(import Config\nconfig :mr_eric, secret: "sk-phase9dummysecret123456789"\n)
    )

    File.mkdir_p!(Path.join(workspace, "priv/cert"))

    File.write!(
      Path.join(workspace, "priv/cert/server.key"),
      "-----BEGIN RSA PRIVATE KEY-----\nphase9dummy\n-----END RSA PRIVATE KEY-----\n"
    )

    :ok
  end

  defp seed_scenario_files(_workspace, _scenario), do: :ok
```

`add_case_opts/2` needs **no** clause for this scenario — the existing catch-all `defp add_case_opts(opts, _eval_case), do: opts` is exactly right. Injecting nothing is the point: no `:rag_context`, no `:rag_module`, so the run drives the real `MrEric.RAG` rooted at the eval workspace through the `workspace_root` opt the runner already passes.

- [ ] **Step 2: Add the scenario to `lib/mr_eric/llm/fake_provider.ex`**

In `scenario_response/3`, add a clause immediately after the `rag_context_used` clause:

```elixir
      scenario == "rag_default_index" and role == :planner ->
        if String.contains?(prompt, "phase9-default-index-marker") do
          # Echo the context back so the scorer can see it. `actual.plan` is
          # scanned by `SecretChecker`, so a secret that reached the index
          # fails the case here rather than going unnoticed.
          {:ok, "plan from default index:\n" <> extract_project_context(prompt)}
        else
          # The real index did not run, or ran and found nothing. Fail on
          # status rather than on `:rag_failed`, which would collide with the
          # orchestrator's own event and make the reason ambiguous.
          {:error, {:fake_failure, :planner}}
        end
```

Add `"rag_default_index"` to the plain-scenario list so non-planner roles do not fall through to `default_response/2`:

```elixir
      scenario in [
        "simple_planning",
        "local_model_failure_continues",
        "rag_context_used",
        "rag_default_index",
        "rag_failure_does_not_break_run",
        "mcp_disabled_is_not_called"
      ] ->
        {:ok, scenario_content(scenario, role)}
```

Add the synthesizer content next to the other `scenario_content/2` clauses, after the `rag_context_used` one:

```elixir
  defp scenario_content("rag_default_index", :synthesizer),
    do: "final plan and implementation from the default index"
```

Add the prompt helper next to the other private helpers at the bottom of the module:

```elixir
  # The planner prompt is "Task: …\n\nProject context:\n<context>\nCreate a
  # concise implementation plan…". Take the context section verbatim so the
  # scorer sees exactly what the index produced.
  defp extract_project_context(prompt) do
    case String.split(prompt, "Project context:", parts: 2) do
      [_before, rest] ->
        rest
        |> String.split("Create a concise implementation plan", parts: 2)
        |> List.first()
        |> String.trim()

      _no_context ->
        ""
    end
  end
```

- [ ] **Step 3: Add the case to `priv/evals/phase9_golden_cases.json`**

Insert after the `rag_failure_does_not_break_run` object (mind the commas):

```json
  {
    "name": "rag_default_index",
    "task": "Summarize the project structure",
    "scenario": "rag_default_index",
    "requires": ["rag"],
    "expected_status": "completed",
    "expected_final_contains": ["default index"],
    "expected_events": ["run_completed"],
    "forbidden_events": ["run_failed", "rag_failed"],
    "expected_no_secret_leak": true
  },
```

- [ ] **Step 4: Run the new case**

Run: `mix mr_eric.evals --case rag_default_index`
Expected: `rag_default_index: passed`.

If it fails on `expected_status`, the marker never reached the planner prompt — check that `Index.build/1` is rooted at the eval workspace and that `README.md` is an indexed extension. If it fails on `:secret_leak`, **stop and report it**: that is a real finding about `Index`'s exclusion rules, not a reason to relax the case.

- [ ] **Step 5: Verify the case can actually fail**

This is a temporary, local-only check — do **not** commit it. Edit `lib/mr_eric/rag/index.ex` and comment out the `.env` entry in `@default_ignored_files`:

```elixir
  @default_ignored_files [
    # ~r/^\.env(\..*)?$/,
    ~r/^secrets?\.exs$/,
    ~r/^prod\.secret\.exs$/
  ]
```

Run: `mix mr_eric.evals --case rag_default_index`
Expected: `rag_default_index: failed`. A case that cannot fail proves nothing.

Then restore the line exactly: `git checkout lib/mr_eric/rag/index.ex`.

- [ ] **Step 6: Run the full suite and all evals**

Run: `mix test && mix mr_eric.evals`
Expected: suite green; `passed=15 failed=0 skipped=0` — fifteen now, not fourteen.

- [ ] **Step 7: Commit**

```bash
git add lib/mr_eric/evals/runner.ex lib/mr_eric/llm/fake_provider.ex priv/evals/phase9_golden_cases.json
git commit -m "test(evals): add the rag_default_index golden case

Deferred from Spec A. Both existing RAG cases bypass the real index, so
Index.build/1 -- the function implementing Spec A's secret-path exclusion
-- had no golden coverage. This one seeds .env, config/dev.secret.exs and
priv/cert/server.key alongside a marker file, injects nothing, and echoes
the received context into the planner stage the secret scanner reads."
```

---

## Task 14: Documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/superpowers/README.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Record the new invariants in `CLAUDE.md`**

In the "Deterministic eval harness (\"Phase 9\")" section, append:

```markdown
- **A golden case cannot assert less than it reads.** `Evals.Case.from_map!/1`
  raises on an unrecognized status, event name, classification, approval action,
  or requirement — an absent optional field means "does not assert that", a
  present-but-unrecognized one means the fixture is wrong. `Scorer.score/2`
  refuses to score an `actual` without a readable `%Trace{}`, reporting
  `:missing_trace`, because `Enum.any?([], _)` is `false` and used to make
  `forbidden_events` pass precisely when nothing was observable. `Evals.run_all/1`
  reports `skipped` by name and reason; `list_cases/0` no longer filters.
- **`actual` carries the planner stage.** `SecretChecker` walks `actual` by
  denylist, so a field that is not there is never scanned — and the planner
  prompt is where RAG context lands.
```

In the "RAG and MCP are deliberately minimal" section, append:

```markdown
- **The RAG index is cached, bounded by bytes.** `MrEric.RAG.Cache` owns an ETS
  table; reads run in the calling process and building stays in the caller, never
  in the GenServer. `Index.fingerprint/1` identifies the tree with an lstat-only
  walk, so an unchanged workspace is never rebuilt and a changed one always is.
  **`allow_secret_paths` is part of the cache key** — it is the only way a cache
  could serve a secret-inclusive index to a caller that asked for the safe one.
  The bound is `max_cached_index_bytes` / `max_cached_total_bytes`, not a chunk
  count: measured, the term maps are 75 % of an index, so a count is not a memory
  bound — the same lesson `max_trace_entries` taught in Spec D.
- **`Retriever` scores from precomputed `:terms` and applies `exact_bonus` only to
  chunks that already scored.** That is sound because `exact_bonus > 0` implies
  `lexical_score > 0`. Note that `tokenize/1` uniqs before frequencies are taken,
  so every term count is `1` and the score counts *distinct* query tokens; do not
  "fix" that into occurrence counting without treating it as a ranking change.
- **RAG failure is visible.** The orchestrator emits `:rag_failed` and continues
  with empty context. It still never fails a run.
```

- [ ] **Step 2: Mark Spec E implemented in `docs/superpowers/README.md`**

Change the Spec E row's status cell and document cell to:

```markdown
| E | eval / RAG の正しさ（scorer early-pass、RAG キャッシュ、`rag_default_index` golden case） | **Implemented**（2026-08-28, `main`） | [spec](./specs/2026-08-28-eval-rag-correctness-design.md) · [plan](./plans/2026-08-28-eval-rag-correctness.md) |
```

Replace the "## 次にやる作業" section body with:

```markdown
**Spec F** が次です。Spec E で eval ハーネスが「主張したことを実際に検証する」状態になり、
RAG 索引のキャッシュと `:rag_failed` の可視化も入りました。残るのは本番 HTTP
（`force_ssl`、HSTS、CSP、`PHX_HOST` の hard-fail）だけです。
```

- [ ] **Step 3: Add the entry to `CHANGELOG.md`**

Under `## [Unreleased]` → `### Added`, add as the first bullet:

```markdown
- eval / RAG の正しさを修正（Spec E、2026-08-28）。
  - `Evals.Case.from_map!/1` が未知の期待値で raise。綴り違いが「より弱い主張」に
    黙って化けなくなった。
  - `Scorer` が trace を読めない `actual` を `:missing_trace` として落とす。
    `forbidden_events` が空振りで通る経路を閉じた。
  - `Evals.run_all/1` と `mix mr_eric.evals` が skipped を名前と理由付きで報告。
  - `actual` に planner ステージを追加し、SecretChecker の走査対象にした。
  - `MrEric.RAG.Cache`（ETS、バイト単位の上限、`allow_secret_paths` をキーに含む）と
    `Index.fingerprint/1` を追加。未変更のワークスペースは再構築しない。
  - `Retriever` が事前計算済みの語を読み、`exact_bonus` を候補のみに適用（実測 17.3×、
    結果は完全一致）。
  - `:rag_failed` イベントを追加。RAG 失敗は run を壊さないまま可視化される。
  - `rag_default_index` golden case を追加（Spec A から先送りされていたもの）。
```

Also update the hardening paragraph to say Spec A–E are on `main` and only Spec F remains:

```markdown
監査由来のセキュリティ hardening は、Spec A–E が `main` に入っており、残りは Spec F です。
```

- [ ] **Step 4: Run the pre-commit gate**

Run: `mix precommit`
Expected: clean — no warnings, no unused deps, all tests pass.

- [ ] **Step 5: Run the evals one final time**

Run: `mix mr_eric.evals`
Expected: `passed=15 failed=0 skipped=0`.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md docs/superpowers/README.md CHANGELOG.md
git commit -m "docs(spec-e): record the eval and RAG correctness invariants"
```

---

## Acceptance checklist

Run through this before declaring Spec E done. Each line maps to a numbered criterion in the spec.

- [ ] `Case.from_map!/1` raises `ArgumentError` naming case, field, and value for an unrecognized status, event name, classification, approval action, or requirement; omitted optional fields still take their documented defaults. *(Task 1)*
- [ ] `Scorer.score/2` reports `:missing_trace` for an `actual` without a readable `%Trace{}`, and no assertion can pass by reading an empty event list. *(Task 2)*
- [ ] `Evals.run_all/1` reports `skipped` by name and reason; `mix mr_eric.evals` prints `passed=N failed=M skipped=K`; `run_case/2` distinguishes an unknown name from a disabled case. *(Task 3)*
- [ ] `actual` includes the planner stage and `SecretChecker` scans it. *(Task 4)*
- [ ] A second `RAG.context_for/2` against an unchanged workspace does not rebuild; any change to a discovered file's `mtime` or `size`, or to the discovered set, does. *(Tasks 7, 9)*
- [ ] Indexes built with different `allow_secret_paths` values never share a cache entry. *(Tasks 8, 9)*
- [ ] `RAG.Cache.fetch!/1` raises for an unknown limit key; `max_cached_index_bytes`, `max_cached_total_bytes`, and `max_cached_indexes` are enforced, and the footprint comes from the cost model rather than a chunk count. *(Task 8)*
- [ ] `Retriever.search/3` produces identical results before and after precomputed terms *and* the deferred `exact_bonus`. *(Task 6)*
- [ ] A failing RAG module produces a `rag_failed` event carrying `error_class: :rag_failed`, and the run still completes. *(Tasks 10, 11)*
- [ ] `rag_default_index` exists, drives the real `Index.build/1`, and was **observed to fail** when a secret-exclusion rule was temporarily removed. *(Task 13, Step 5)*
- [ ] `mix precommit` passes and `mix mr_eric.evals` reports `passed=15 failed=0 skipped=0`. *(Task 14)*
