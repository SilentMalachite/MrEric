# Spec E — Eval and RAG Correctness

- **Date:** 2026-08-28
- **Status:** Designed (not yet implemented)
- **Plan:** `docs/superpowers/plans/2026-08-28-eval-rag-correctness.md`
- **Scope:** Fifth of six hardening specs derived from the 2026-05-05 audit report.
- **Tracks audit findings:** eval assertions that pass vacuously, an eval suite that can silently shrink to green, RAG index rebuilt on every planner call, RAG failure indistinguishable from RAG emptiness, and the `rag_default_index` golden case deferred from Spec A.
- **Threat model:** Local single-user dev tool. The adversary here is not a remote attacker and not time — it is *a green check mark that means nothing*. Specs A–D each installed a boundary; this spec is about whether the harness that is supposed to prove those boundaries hold actually proves anything. A secret-exclusion rule nobody exercises is a rule you find out about from a leak.

## Background

Specs A–D closed the secret, ownership, tool-execution, and lifetime boundaries. Every one of them ends with an acceptance criterion of the form "the golden eval suite still passes". That sentence is only worth something if the suite can fail.

Today it can fail less than it looks. Six concrete gaps, all present on `main`:

**1. Unknown expectation values are silently discarded.** `MrEric.Evals.Case.from_map/1` normalizes every declared expectation through a lookup with a fallback:

- `events/1` maps each name through `@events` and then `Enum.reject(&is_nil/1)` (`case.ex:128-138`). A misspelled event name does not raise — it *disappears from the list*. `expected_events: ["run_compelted"]` becomes `expected_events: []`, and `Enum.all?([], …)` is `true`. A `forbidden_events` typo is worse: the assertion becomes unconditionally satisfied.
- `classification/1` returns `nil` for an unrecognized string (`case.ex:144-146`). `nil` is exactly the value that selects `Scorer.assert_error_classification/3`'s no-op clause (`scorer.ex:127-133`). A typo turns the assertion off.
- `status/1` returns `:completed` for an unrecognized string (`case.ex:124`). A case that meant `"failed"` and typed `"faield"` asserts the opposite of what it says.

The pattern is the one Spec C-1 named: *a lookup with a default fails open.* Here it fails open into a passing test.

**2. A missing trace makes assertions vacuous.** `Scorer.trace_events/1` ends in `defp trace_events(_actual), do: []` and `trace_summary/1` in `defp trace_summary(_actual), do: %{}` (`scorer.ex:145, 152`). With `[]`, `assert_forbidden_events/3` evaluates `Enum.any?([], …)` — `false` — and *passes*. The one assertion whose whole job is to prove an event did not happen is satisfied by not being able to see events at all. `Runner` builds a `%Trace{}` on both the success and the error path, so no live input reaches these clauses; they exist only to turn an impossible shape into a green result.

**3. Disabled cases are invisible in the report.** `Evals.list_cases/0` filters by `enabled?/1` *before* anything counts (`evals.ex:11-18`), and `run_all/1` derives `failed` as `length(results) - passed` over that already-filtered list (`evals.ex:42-43`). `Case.requirement_available?/1` ends in `defp requirement_available?(_requirement), do: false` (`case.ex:112`) — an unrecognized requirement disables the case. So a single typo in `requires` removes a case from the suite, and `mix mr_eric.evals` prints `passed=13 failed=0` with no indication that it used to be 14. Nothing is dropped today (all 14 cases run), but the mechanism is live.

Relatedly, `Evals.run_case/2` returns `{:error, :unknown_eval_case}` for a case that exists but is disabled — the wrong reason, reported as if the name were wrong.

**4. The RAG index is rebuilt from scratch on every planner call.** `RAG.context_for/2` calls `Index.build/1` unless the caller passes a prebuilt `opts[:rag_index]` (`rag.ex:26-31`). `Index.build/1` walks the workspace, `File.read`s every eligible file, and chunks all of them. Nothing caches the result between runs. The two orchestrator call sites (`orchestrator.ex:114` in `run_planner/2`, `orchestrator.ex:205` in the streaming planner) are mutually exclusive paths, so a single run builds once — but the ordinary dev loop is *run, adjust, run again* against an unchanged tree, and every one of those runs pays the full cost.

`Retriever.score/3` compounds it: it recomputes `content |> tokenize() |> Enum.frequencies()` for **every chunk on every search** (`retriever.ex:27-46`). That work is a pure function of the chunk and is thrown away after each query.

**5. RAG failure is completely silent, and one golden case depends on that.** `Orchestrator.do_rag_context_for/2` wraps the call in a bare `rescue`/`catch` that collapses everything to `""` (`orchestrator.ex:790-806`). Not failing the run is correct and stays. Saying nothing is not: `:rag_failed` exists in `Errors.classifications/0` and in `Case`'s `@classifications` table, and nothing anywhere emits it. The consequence is that `rag_failure_does_not_break_run` — whose entire subject is a RAG module that raises — cannot distinguish "RAG raised and we recovered" from "RAG returned nothing". It passes either way.

**6. `rag_default_index` does not exist.** Spec A's Task 11 wrote the case, discovered there was no scenario to attach it to, and deferred the fixture wiring here (`plans/2026-05-05-secret-hygiene.md:1072-1086`). The result is that both existing RAG cases bypass the real index — `rag_context_used` injects `opts[:rag_context]` as a literal string, `rag_failure_does_not_break_run` swaps in `MrEric.Evals.RaisingRAG`. `Index.build/1` — the function that implements Spec A's secret-path exclusion — is exercised by unit tests and by no golden case at all.

### What is *not* broken

Three things that look adjacent and are already correct; this spec does not change them:

- **RAG failure does not fail a run.** That is a requirement, not a bug (`CLAUDE.md`: "RAG failures must not fail a run"). Section 6 makes the failure *visible*; the run still completes with empty context.
- **`SecretChecker` scans by denylist, not allowlist.** Spec A already made it walk the whole `actual` map minus a small metadata denylist (`secret_checker.ex:16-18, 27`), so any field added to `actual` is scanned by default. Section 4 exploits that property rather than working around it.
- **The eval harness is independent of run lifetime.** Spec D gave the eval runner its own `RunSupervisor` with `max_children: 64` and a 1 s `terminal_run_ttl_ms`, precisely so golden cases never race a production-sized cap (`runner.ex:25-26, 61, 71`). Nothing here touches that arrangement.

## Goals

1. Make it impossible for a golden case to assert less than it reads. An unrecognized expectation value raises; it never degrades into a weaker assertion.
2. Remove every scorer clause that turns an unreadable result into a pass.
3. Make a shrinking suite visible: report skipped cases by name and reason, and never let a skip look like a pass.
4. Put the planner stage — where RAG context lands — under the secret scanner.
5. Stop rebuilding an unchanged RAG index, without ever serving stale context, and without letting a cache cross the `allow_secret_paths` boundary. Bound what is cached by measured bytes, not by a proxy.
6. Emit `:rag_failed` when RAG fails, while keeping the run alive on empty context.
7. Land the `rag_default_index` golden case Spec A deferred, driving the *real* `Index.build/1` against a workspace seeded with secret-shaped files.

## Non-Goals

- **Vector search, embeddings, hybrid retrieval, or a RAG UI.** Out of scope by standing project rule; caching is explicitly the only RAG feature Spec A deferred here (`specs/2026-05-05-secret-hygiene-design.md:32`).
- **Persisting the index.** No Ecto, no disk cache. The cache dies with its owning process, like every other piece of state in this app.
- **Rewriting the scorer's assertion vocabulary.** The set of assertions stays as it is; this spec is about the ones that pass when they should not.
- **Making the eval suite non-deterministic.** No timing-dependent assertions, no cache-hit counters in the golden-case schema. Cache behaviour is proved by unit tests.
- **Production HTTP hardening (Spec F).**

## Architecture overview

Three independent changes, in dependency order:

```
Section 1 (Case)      strict parsing — unknown value raises
Section 2 (Scorer)    no vacuous pass — unreadable actual fails
Section 3 (Evals)     skipped cases are reported, not dropped
Section 4 (Runner)    planner stage enters `actual`
          ↓ (Sections 1-4 are the harness; 5-7 are what it now proves)
Section 5 (RAG cache) fingerprint-validated ETS cache, byte-bounded; faster search
Section 6 (rag_failed) orchestrator emits a real event on RAG failure
Section 7 (golden)    rag_default_index drives the real index
```

Sections 5–7 each depend on the harness being honest first, which is why the harness work lands first. Section 7 depends on Section 4 (planner stage in `actual`) and on Section 6 (an event to forbid).

## Section 1 — Strict eval-case parsing

`MrEric.Evals.Case.from_map/1` becomes `from_map!/1` and raises `ArgumentError` on any value it cannot map:

| Field | Today | After |
|-------|-------|-------|
| `expected_status` | unknown string → `:completed` | unknown string → raise; `nil` → `:completed` |
| `expected_events` / `forbidden_events` | unknown element dropped | unknown element → raise; `nil` → `[]` |
| `expected_error_classification` | unknown string → `nil` (assertion off) | unknown string → raise; `nil` → `nil` (assertion deliberately absent) |
| `approval_action` | unknown string → `nil` | unknown string → raise; `nil` → `nil` |
| `requires` | unknown requirement → case silently disabled | unknown requirement → raise |

The distinction that matters: **absent** and **unrecognized** are different. An omitted `expected_error_classification` means "this case does not assert a classification" and stays legal. A present-but-unrecognized one means the fixture is wrong and must stop the suite.

The raised message names the case, the field, and the offending value. All three are fixture text, not run data — there is nothing secret in a golden case's own field names.

`Case.enabled?/1` keeps its meaning (`requires` all satisfied), but `requirement_available?/1` no longer needs a fail-closed catch-all for unknown names, because `from_map!/1` rejected those at parse time. It keeps one clause per known requirement and no default.

### Tests

- `from_map!/1` raises for a bad status, a bad event name in each of the two event lists, a bad classification, a bad approval action, and a bad requirement.
- `from_map!/1` accepts a map that omits every optional field and returns the documented defaults.
- The real `priv/evals/phase9_golden_cases.json` parses without raising (this is the regression guard that keeps the fixture honest).

## Section 2 — No vacuous scorer passes

Delete `defp trace_events(_actual), do: []` and `defp trace_summary(_actual), do: %{}`.

`Scorer.score/2` reads the trace once, up front:

- If `actual` carries a `%Trace{}`, scoring proceeds against its events and summary.
- Otherwise scoring stops with a single `:missing_trace` failure. It does not fall through to the individual assertions, because their verdicts on a missing trace are meaningless.

The `%{entries: entries}` compatibility clause in `trace_events/1` (`scorer.ex:149-150`) stays — it reads a real, populated shape. Only the catch-alls go.

### Tests

- An `actual` with no `:trace` key fails with `:missing_trace`, not with a pass.
- An `actual` whose `:trace` is `nil` fails the same way.
- A case with `forbidden_events` and a trace that genuinely lacks those events still passes (the change must not turn a legitimate pass into a failure).

## Section 3 — Skipped cases are reported

`MrEric.Evals` gains an explicit partition:

- `list_cases/0` returns **all** parsed cases, unfiltered. (Callers that want only runnable ones say so.)
- `partition_cases/0` returns `{enabled, skipped}`.
- `run_all/1` returns `%{passed:, failed:, skipped:, results:}` where `skipped` is a list of `%{case: name, requires: [...]}`. `failed` is counted from results, not derived by subtraction, so a future third status cannot silently land in the failed bucket.
- `run_case(name, opts)` distinguishes three outcomes: unknown name → `{:error, :unknown_eval_case}`; known but disabled → `{:error, {:case_disabled, requires}}`; runnable → as today.

`Mix.Tasks.MrEric.Evals` prints one line per skipped case (`<name>: skipped (requires: mcp)`) and a summary line `passed=N failed=M skipped=K`. Skips do not fail the task — a machine without MCP modules is a legitimate configuration — but they are never invisible again.

### Tests

- `partition_cases/0` splits a fixture list correctly.
- `run_all/1` reports a skipped case in `skipped` and does not count it as passed.
- `run_case/2` returns `{:error, {:case_disabled, _}}` for a known-but-disabled case.
- The mix task's summary line includes `skipped=`.

## Section 4 — The planner stage enters `actual`

`Runner.execute_case/3` adds `plan: Run.stage(run, :planner)` to the map it returns (`runner.ex:84-97`).

This is a one-line change with two consequences. First, `SecretChecker.scan/1` — which walks the whole `actual` map by denylist — now covers the planner's prompt-derived output, the one place RAG context reaches a model. Second, Section 7's golden case becomes expressible: a planner that echoes its context puts that context somewhere the scorer can see.

The existing cases are unaffected: no current scenario puts a secret in planner output, and `expected_final_contains` still reads `final`.

### Tests

- `actual` from any run includes `:plan`.
- A scenario whose planner output contains a secret-shaped string fails `expected_no_secret_leak` (proving the new field is actually scanned).

## Section 5 — The RAG index cache

### 5a. Fingerprint

`Index.discover_paths/2` already calls `File.lstat` on every entry it walks (`index.ex:90`). It is widened to carry `{relative_path, mtime, size}` instead of `relative_path` alone; `build/1` projects out the paths. The fingerprint is `:erlang.phash2` of that list, sorted.

When the caller passes `opts[:paths]` / `opts[:rag_paths]`, discovery is skipped, and the fingerprint is built from `File.stat` on each named path.

Cost: zero additional syscalls on the discovery path. The walk is the cheap half; `File.read` + chunking + tokenizing is what the cache saves.

### 5b. The cache key

Everything that can change the *content* of an index is part of its key:

```
{workspace_root, allow_secret_paths, include_extensions, extra_ignored_dirs,
 normalized_extra_ignored_files, max_file_bytes, chunk_size, chunk_overlap,
 explicit_paths}
```

`extra_ignored_files` is a list of `Regex`; it is normalized to `{Regex.source(r), Regex.opts(r)}` pairs rather than relying on `inspect/1`.

**`allow_secret_paths` is in the key, and that is the security-critical part of this section.** It is the flag that decides whether `config/`, `priv/cert/`, `priv/secrets/`, and `Policy.secret_path?/1` matches are walked at all (`index.ex:60-64, 95, 106`). A key that omitted it would let an index built for a caller that asked for secrets be served to a caller that asked for the safe one — the single way a cache can reopen the boundary Spec A closed. Key construction lives in exactly one function, `RAG.Cache.key/1`, so there is no second place for it to drift.

### 5c. `MrEric.RAG.Cache`

A GenServer added to the supervision tree in `MrEric.Application.start/2`, owning an ETS table (`:set`, `:protected`, `read_concurrency: true`). The table is owned by the process, so the cache cannot outlive it.

- `fetch(key, fingerprint)` → `{:ok, index} | :stale | :miss`. Runs **in the calling process** as a direct `:ets.lookup/2`. No `GenServer.call` on the read path.
- `put(key, fingerprint, index)` → `GenServer.call`. The only serialized operation; it applies the bounds.
- `flush/0` → clears the table. For tests.

Building is done by the **caller**, never inside the GenServer. This is Spec D's lesson applied verbatim: `Executor.request_tool/4` used to run inside `RunWorker` and a hung `System.cmd/3` blocked the worker's own deadline. `Index.build/1` reads an unbounded number of files; it does not belong in a process everything else waits on. The cost is that two simultaneous misses on the same key both build. That happens once, produces identical results, and is cheaper than the alternative.

**Limits.** `@defaults` in `RAG.Cache` is the only place a number is written; `config :mr_eric, :rag_cache` is override-only; `fetch!/1` has no catch-all clause and no default parameter, so an unknown key raises at the call site. Same contract as `MrEric.Runs.Limits`, deliberately a separate one — run lifetime and index memory are different subjects and `Runs.Limits.fetch!/1` must keep raising on keys that are not about runs.

**The bound is bytes, not chunks.** An earlier draft of this section capped `max_cached_chunks`. That is the same mistake Spec D made with the trace and had to correct — `CLAUDE.md` records the outcome as "the trace is bounded by size, not only by entry count". A chunk's `content` is capped by `chunk_size`, but the `:terms` map attached in 5e is not capped by anything the cache controls, and measurement shows it is the larger half.

Measured on this repository (`Index.build/1`, default opts, 2026-08-28):

| Quantity | Value |
|----------|-------|
| Files indexed | 148 |
| Chunks | 819 |
| Chunk `content` (refc binaries) | 1.16 MiB |
| Chunk structures (heap) | 0.17 MiB |
| `:terms` + `:path_terms` maps (heap) | 3.99 MiB |
| **Total resident** | **5.32 MiB — 6,811 B per chunk** |

So the index costs roughly **4.6× the raw indexable text**, and 75 % of that is the term maps. A `max_cached_chunks: 20_000` cap would have permitted ~136 MiB per index and ~544 MiB across four of them.

**The cost model.** `put/3` needs the footprint without walking the heap, so it computes

```
index_bytes = Σ_chunks [ byte_size(content) + Σ_terms (byte_size(term) + 48) + 200 ]
```

The 48 B/entry is the measured map-entry overhead (75,719 entries, 4,183,256 B of heap, 481,435 B of that in key bytes → 48.8 B of overhead per entry); the flat 200 B/chunk covers the chunk map itself. The model predicts 5.28 MiB against a measured 5.32 MiB — **within 1.6 %** — which is accurate enough for a bound and costs one arithmetic pass.

| Limit | Default | Derivation |
|-------|---------|------------|
| `max_cached_index_bytes` | 24_000_000 | ≈ 4.5× this repository's index. A project several times larger than MrEric still caches; anything beyond is returned to the caller and not stored. |
| `max_cached_total_bytes` | 48_000_000 | The real ceiling: two full-size indexes, or ~9 of this repository. For scale, the run side budgets ~8 MiB (`max_trace_payload_chars` × `max_trace_entries` × `max_concurrent_runs`). |
| `max_cached_indexes` | 4 | Key-count guard only, so many tiny workspaces cannot grow the table without limit. Eviction is least-recently-read. |

### 5d. Flow

```
opts[:rag_index] present?  → use it (existing escape hatch, unchanged)
otherwise:
  key = Cache.key(opts)
  fp  = Index.fingerprint(opts)          # lstat only
  case Cache.fetch(key, fp)
    {:ok, index} → use it
    :stale | :miss → Index.build(opts_with_fingerprint) → Cache.put(key, fp, index)
```

`Index.build/1` accepts the already-computed fingerprint (and the discovery result it came from) through opts so the tree is walked once per `context_for/2`, not twice.

### 5e. Precomputed term frequencies **and a deferred exact bonus**

Two changes to `Retriever`, and they only pay off together.

`Chunker.chunk_text/3` attaches `:terms` and `:path_terms` to each chunk; `Retriever.score/3` reads them instead of recomputing.

**`:terms` must be built the way `Retriever` builds them today, not the way the name suggests.** `Retriever.tokenize/1` ends in `Enum.uniq/1` (`retriever.ex:53`), and `score/3` then calls `Enum.frequencies/1` on that already-deduplicated list (`retriever.ex:30-31`) — so every "frequency" in the shipping scorer is `1`, and the lexical score counts *distinct* query tokens present, not occurrences. Storing real occurrence counts would silently change every ranking. `:terms` is therefore `content |> tokenize() |> Enum.frequencies()` with `tokenize/1` unchanged, uniq included, and the values are all `1`. Memory is unaffected: the key set is identical and small integers are immediates.

Whether counting occurrences would retrieve better is a retrieval-quality question, and §8 puts those outside this spec. Recorded here so the `1`s are not later "fixed" into a ranking change nobody asked for.

`Retriever.search/3` then computes the lexical score for every chunk, **filters to `score > 0`, and applies `exact_bonus` only to the survivors**. This is behaviour-preserving: `exact_bonus` fires when the chunk's downcased content contains the whole downcased query, which implies the content contains every query token, which implies a non-zero lexical score. `exact_bonus > 0 ⟹ lexical_score > 0`, so the survivors are a superset of the chunks the bonus can reach. (The degenerate case — a query whose tokens are all shorter than two characters — already returns `[]` before scoring.)

Measured on this repository's 819-chunk index (min of 7 trials, 15 iterations each, warmed):

| Variant | Per query | vs today |
|---------|-----------|----------|
| A — today: tokenize live, `exact_bonus` on every chunk | 137.07 ms | — |
| B — precomputed terms only | 55.94 ms | 2.5× |
| C — deferred `exact_bonus` only | 178.30 ms | **0.8× (slower)** |
| D — both | **8.65 ms** | **15.8×** |

Each change alone leaves the other cost dominating: with live tokenization the bonus is not the bottleneck (C adds a pass and loses), and with the bonus still running over all 819 chunks the per-query `String.downcase/1` over 1.16 MiB dominates (B). Doing only one of them is not worth 4 MiB of resident memory; doing both is.

That A/B/C/D comparison was made between four variants written for the benchmark, so it only shows the two changes are complementary. The claim that matters — the proposal returns what the code returns today — was checked separately against `MrEric.RAG.Retriever.search/3` itself, with `:terms` built the uniq-preserving way described above: **identical `{path, start_line, score}` triples in identical order across ten queries**, including a no-match query, a single-token query, a stop-word query, a punctuated one, and the degenerate `"a"` (all tokens shorter than two characters → no hits). Against the shipping function the speedup measures **17.3×** (149.03 ms → 8.63 ms).

A chunk without `:terms` — one handed in through `opts[:rag_index]` by a caller holding an older shape — gets its frequencies computed in an explicit fallback clause. This is a *performance* fallback and is safe: the value it computes is the same value the index would have stored. It is not the "lookup with a default" pattern Spec C-1 banned, because nothing about a boundary depends on it. The distinction is stated here so a later reader does not delete it for the wrong reason, or add a similar default somewhere it *would* matter.

**Rejected: an inverted index.** A `term → [{chunk, count}]` map looked like the obvious way to stop paying map-entry overhead 75,719 times instead of 8,124. Measured, it is **1.19× smaller** — 3.35 MiB against 3.99 MiB — because the postings tuples and list cells reproduce almost exactly the overhead the map entries had. It would still speed up search by touching only chunks that contain a query term, but that is not what these limits are about, and D already gets 15.8× without restructuring `Retriever`'s data model. Recorded here so the idea is not re-derived and re-implemented on the same wrong prediction.

### Tests

- Two `context_for/2` calls against an unchanged workspace build the index once (asserted with a build counter injected through opts, not with timing).
- Touching an indexed file changes the fingerprint and forces a rebuild.
- Adding a new eligible file forces a rebuild.
- **`allow_secret_paths: true` and `allow_secret_paths: false` never share a cache entry**, and a secret-inclusive index is never returned to a caller that did not ask for one.
- Differing `include_extensions`, `max_file_bytes`, `chunk_size`, and `extra_ignored_files` each produce distinct keys.
- `max_cached_indexes` evicts the least recently read entry; the evicted key rebuilds on next use.
- An index exceeding `max_cached_index_bytes` is returned but not stored.
- Inserting indexes past `max_cached_total_bytes` evicts least-recently-read entries until the total fits.
- The `index_bytes/1` cost model is asserted against a hand-computed fixture, so a change to the chunk shape that alters the footprint is visible.
- `Cache.fetch!/1` raises for an unknown limit key.
- `Retriever.search/3` returns identical `{path, start_line, score}` triples, in identical order, across all four variants (live/precomputed terms × eager/deferred `exact_bonus`), over a query set that includes a no-match query, a single-token query, a stop-word query, and a punctuated query.

## Section 6 — `:rag_failed` becomes a real event

`MrEric.Runs.Events` gains `:rag_failed` in its closed list of names. `MrEric.Evals.Case`'s `@events` table gains the matching `"rag_failed"` string.

`Orchestrator.do_rag_context_for/2` keeps its current contract — on any failure the planner proceeds with empty context and the run completes — and additionally emits `{:rag_failed, %{run_id: …, error_class: :rag_failed, error: <sanitized>}}`.

The error message goes through `MrEric.Errors.redact/1` like every other error that reaches an event. Per `CLAUDE.md`, classification is taken once at `Events.normalize_event/2` and carried as `:error_class`; this event supplies `:rag_failed` there and nothing downstream re-derives it by matching on the sanitized text.

`rag_failure_does_not_break_run` then gains `"rag_failed"` in `expected_events` and `"run_failed"` in `forbidden_events`. Today that case passes whether or not the RAG module ever raised; afterwards it passes only for the reason it was written.

### Tests

- A raising RAG module produces a `rag_failed` event and a completed run.
- The emitted event carries `error_class: :rag_failed`.
- The event's payload survives `SecretChecker.scan/1` when the RAG module raises with a secret-shaped message.
- A RAG module that legitimately returns `{:ok, ""}` emits **no** `rag_failed` event.

## Section 7 — The `rag_default_index` golden case

The case Spec A wrote and could not wire up.

**Workspace.** `Runner.setup_workspace/1` becomes scenario-aware. For `rag_default_index` it seeds, alongside the existing `note.txt`:

| Path | Content | Why |
|------|---------|-----|
| `README.md` | text containing `phase9-default-index-marker` | Proves the real index ran and reached the planner. |
| `.env` | `OPENAI_API_KEY=sk-phase9dummysecret123456789` | `Policy` protects `.env*`; `Index` also ignores it by name. |
| `config/dev.secret.exs` | a secret-shaped assignment | `config/` is in `@default_ignored_dirs` unless `allow_secret_paths`. |
| `priv/cert/server.key` | a PEM `BEGIN RSA PRIVATE KEY` block | `.key` is in `@default_ignored_extensions`; `priv/cert` in `@secret_dirs`. |

Every seeded secret is a fixed dummy value in the repo, matched by `SecretChecker`'s patterns (`named_api_key`, `env_content`, `private_key`).

**Wiring.** `Runner.add_case_opts/2` injects **nothing** for this scenario — no `:rag_context`, no `:rag_module`. The run therefore drives the real `MrEric.RAG` and the real `Index.build/1`, rooted at the eval workspace via the `workspace_root` opt the runner already passes.

**Provider.** `FakeProvider`'s planner clause for `rag_default_index`:

- Prompt lacks `phase9-default-index-marker` → `{:error, {:fake_failure, :planner}}`. The real index did not run, or ran and found nothing; either way the case must fail, and it fails on `expected_status`. (Deliberately *not* `{:error, :rag_failed}` — that would collide with Section 6's event and make the failure ambiguous.)
- Prompt has the marker → the planner echoes the received `Project context:` section into its own output.

The echo is what makes the case meaningful. Section 4 put the planner stage in `actual`; `SecretChecker` walks `actual`; so if any seeded secret survived into the index, the case fails with `:secret_leak` rather than passing quietly.

**The case:**

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
}
```

### Tests

- The case passes as written.
- Removing `.env` from the index's ignore rules makes the case fail with `:secret_leak` (verified as a temporary local check during implementation, not committed — the committed guard is the case itself plus the existing `Index` unit tests).
- The scenario is listed in `FakeProvider`'s scenario tables so it does not fall through to `default_response/2`.

## Section 8 — What is *not* addressed, and why

- **`Retriever`'s scoring quality.** Lexical overlap with a path-token bonus stays exactly as it is. Section 5e changes *where* the term frequencies come from, never how they are scored. Retrieval quality is not a correctness boundary and belongs to no spec in this series.
- **`expected_final_contains: []` passing vacuously.** `Enum.all?([], …)` is `true`, and that is correct: a case that names no expected substring is asserting nothing about `final` on purpose (`cancelled_run` and `provider_missing_api_key_error` both rely on it). The Section 1 fix is about values that were *written and lost*, not about values that were never written.
- **Approval-expiry LiveView rendering.** Deferred from Spec B (`plans/2026-05-05-run-ownership.md:1894`) and still deferred: it needs LiveView integration setup, not eval-harness work.

## Risks and follow-ups

| Risk | Mitigation |
|------|------------|
| The cache key omits an option that changes index content, so two different indexes collide. | Key construction is one function; the test matrix asserts a distinct key per content-affecting option. A new `Index` option that is not added to the key is a review-visible omission because both live in the same module pair. |
| `allow_secret_paths` leaks across the key. | Explicit test; called out in the module doc for `RAG.Cache.key/1`. |
| `mtime` granularity (1 s on some filesystems) hides a same-second edit. | Fingerprint includes `size` as well as `mtime`. A same-second, same-size edit is possible in principle; the cost is one stale planner context in a dev tool, and the alternative (hashing every file) costs exactly what the cache is meant to save. Recorded here rather than mitigated. |
| Strict parsing turns an existing valid fixture into a raise. | The committed fixture is parsed in a test, and the whole suite runs in `mix precommit`. |
| The byte budget (24 MB per index, 48 MB total) is derived from one repository. | The derivation is written down in 5c so it can be re-run: measure `Index.build/1` on the workspace in question and compare. A project whose index exceeds the cap is not cached — it degrades to today's behaviour, which is correct but slow, and is the loudest possible signal that the budget wants raising. |
| Two callers miss simultaneously and both build. | Accepted. Identical results, bounded by the same limits, and cheaper than serializing builds through the cache process. |

## Acceptance criteria

1. `Case.from_map!/1` raises `ArgumentError` — naming case, field, and value — for an unrecognized status, event name, classification, approval action, or requirement; omitted optional fields still take their documented defaults.
2. `Scorer.score/2` reports `:missing_trace` for an `actual` without a readable `%Trace{}`, and no assertion can pass by reading an empty event list.
3. `Evals.run_all/1` reports `skipped` by name and reason; `mix mr_eric.evals` prints `passed=N failed=M skipped=K`; `run_case/2` distinguishes an unknown name from a disabled case.
4. `actual` includes the planner stage, and `SecretChecker` scans it.
5. A second `RAG.context_for/2` against an unchanged workspace does not rebuild the index; any change to a discovered file's `mtime` or `size`, or to the discovered set, does.
6. Indexes built with different `allow_secret_paths` values never share a cache entry.
7. `RAG.Cache.fetch!/1` raises for an unknown limit key; `max_cached_index_bytes`, `max_cached_total_bytes`, and `max_cached_indexes` are enforced, and the footprint is computed by the 5c cost model rather than by chunk count.
8. `Retriever.search/3` produces identical results before and after precomputed terms *and* the deferred `exact_bonus`, and the pair is measurably faster than either alone.
9. A failing RAG module produces a `rag_failed` event carrying `error_class: :rag_failed`, and the run still completes.
10. `rag_default_index` exists, drives the real `Index.build/1`, and fails if a seeded secret reaches the planner.
11. `mix precommit` passes and `mix mr_eric.evals` reports `failed=0` with the new case counted.

## Out of scope (tracked elsewhere)

- Spec F — production HTTP (`force_ssl`, HSTS, CSP, `PHX_HOST` hard-fail).
- Phase 7 advanced RAG (vector DB, embeddings, hybrid search, RAG UI).
- Phase 8 real MCP connections (server startup, discovery, proxy, MCP UI).
- Ecto / DB persistence, login and multi-user authentication.
- `git commit` / `push` / `reset` / `clean`, force push, automatic rollback.
