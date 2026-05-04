# Spec A — Emergency Secret Hygiene

- **Date:** 2026-05-05
- **Status:** Draft (awaiting user review)
- **Scope:** First of six security-hardening specs derived from the 2026-05-05 audit report.
- **Tracks audit findings:** #2 (`secret_key_base` committed), #13 (`SecretChecker.sensitive_key?` inverted), #14 (RAG indexes `config/`), and the medium-severity `shell_command` env scrub deny-list.

## Background

A multi-agent audit of the MrEric codebase identified 23 issues across web, tools, orchestrator, and eval layers. The current spec covers the smallest, most urgent slice: anything that materially increases the chance of a secret leaving the host.

Four concrete defects motivate this spec:

1. `secret_key_base` is hardcoded in `config/dev.exs:15` and `config/test.exs:6`. The values are public on git history.
2. The RAG default index walks `config/`, so re-indexing this repository ships `secret_key_base` (and any other key in `config/dev.exs`) into planner prompts.
3. `MrEric.Evals.Scorer.sensitive_key?/1` (around `lib/mr_eric/evals/scorer.ex:68`) drops values whose *key name* looks sensitive (`api_key`, `password`, `token`). The whole subtree under that key is therefore exempt from secret scanning — exactly the opposite of the intended behaviour.
4. `lib/mr_eric/tools/shell_command.ex:57-59` scrubs a small deny-list of env vars (`OPENAI_API_KEY`, `AWS_*`). Everything else (`GITHUB_TOKEN`, `DATABASE_URL`, `STRIPE_*`, `npm_config_*`, …) is inherited by every approved shell command.

The remaining audit findings (run ownership, tool boundary hardening, run lifetime/resources, eval/RAG correctness, production config) are tracked in subsequent specs B–F.

## Goals

- Invalidate the published `secret_key_base` values so existing leaks become moot once a new release is deployed.
- Make `config/`, `.env*`, certificates, and other secret-bearing files unreadable to the RAG indexer by default.
- Fix `SecretChecker` so the eval harness actually detects leaks under sensitive keys and across all run channels.
- Replace the shell environment deny-list with an allow-list, configurable but safe by default.

## Non-Goals

- Rewriting git history to remove the leaked `secret_key_base` values. The mitigation is rotation; history rewrite is rejected as disproportionate for this repo.
- Adding new RAG features (caching, ETS-backed index, etc.). Caching is in Spec E.
- Touching the run ownership / approval model (Spec B), the tool boundary logic (Spec C), the run supervisor (Spec D), or production HTTP config (Spec F).

## Section 1 — Rotate `secret_key_base` and centralise via `runtime.exs`

### Changes

- Remove the hardcoded `secret_key_base:` line from:
  - `config/dev.exs` (currently line 15)
  - `config/test.exs` (currently line 6)
- Move all `secret_key_base` resolution into `config/runtime.exs`, applying to **all environments**, not just `:prod`:
  - `:prod`: keep `System.fetch_env!("SECRET_KEY_BASE")` — hard fail if missing.
  - `:dev` / `:test`: prefer `System.get_env("SECRET_KEY_BASE")`. If unset, generate a fresh value with `:crypto.strong_rand_bytes(48) |> Base.encode64()` and emit `Logger.warning("SECRET_KEY_BASE not set; using a random value for this boot")`. Random regeneration per boot is acceptable in dev/test and avoids per-developer setup friction.
- **Out of scope here:** the `signing_salt` values in `lib/mr_eric_web/endpoint.ex` and `config/config.exs:24` are deliberately left as static literals. Phoenix treats signing salts as compile-time constants (they label different signed-token domains), and the audit notes they are only weaponisable when combined with a leaked `secret_key_base`. Rotating the key base is sufficient.
- Add `.env` and `.env.*` to `.gitignore` (currently absent — verified). Keep `.env.example` tracked.
- Create `.env.example` at the repo root with placeholders:
  ```
  SECRET_KEY_BASE=
  PHX_HOST=localhost
  OPENAI_API_KEY=
  # See README for the full list
  ```
- Update `README.md` "クイックスタート" section: add `cp .env.example .env` and "edit values as needed" steps. Note that `SECRET_KEY_BASE` may be left blank in dev — the app will generate one.

### Tests

- New file `test/mr_eric_web/endpoint_config_test.exs` (or extend an existing one):
  - `assert Application.fetch_env!(:mr_eric, MrEricWeb.Endpoint)[:secret_key_base]` is non-nil and ≥ 64 bytes after boot.
- New file `test/config_hygiene_test.exs`:
  - Reads `config/dev.exs` and `config/test.exs` raw, asserts they do **not** contain a literal `secret_key_base:` assignment. Acts as a regression guard against re-introducing hardcoded values.

### Out of scope for this section

- Rotating `OPENAI_API_KEY` etc. — those are user-provided runtime secrets and not committed.
- Replacing `Phoenix.Token` salts in any endpoint helpers (audit did not flag specific instances).

## Section 2 — RAG default exclusion of secret-bearing paths

### Changes

- In `lib/mr_eric/rag/index.ex`:
  - Expand `@default_ignored_dirs` to:
    ```
    [".git", "deps", "_build", "node_modules", ".elixir_ls",
     "priv/static", "config", "priv/cert", "priv/secrets",
     ".serena", ".expert", ".idea", ".claude"]
    ```
  - Add `@default_ignored_files` (basename regexes):
    ```
    [~r/^\.env(\..*)?$/, ~r/^secrets?\.exs$/, ~r/^prod\.secret\.exs$/]
    ```
  - Add `@default_ignored_extensions`:
    ```
    ~w(.pem .key .p12 .pfx .cer .crt .pkcs12 .jks .asc .gpg)
    ```
- Refactor `discover_dir/5` (current entry point for filesystem walking) into two filtering stages:
  1. Skip a directory if its basename is in `ignored_dirs` (computed = default ∪ user-supplied).
  2. For each file, skip if (a) basename matches any `ignored_files` regex, (b) extension is in `ignored_extensions`, **or** (c) `MrEric.Tools.Policy.secret_path?(rel_path)` returns true.
- Promote `MrEric.Tools.Policy.secret_path?/1` to a public function (it currently lives near `lib/mr_eric/tools/policy.ex:254`). Add `@spec secret_path?(Path.t()) :: boolean()` and a moduledoc note that the function is shared between Policy and RAG. The single source of truth means future Policy updates automatically tighten RAG.
- Extend `Index.build/2` opts:
  - `:extra_ignored_dirs` (list of basename strings) — appended to defaults.
  - `:extra_ignored_files` (list of `Regex.t()`) — appended to defaults.
  - `:allow_secret_paths` (boolean, default `false`) — when `true`, skips the `Policy.secret_path?/1` filter. Used only by tests.

### Tests

- Extend `test/mr_eric/rag/index_test.exs`:
  - Set up a temp workspace with a fake `config/dev.exs` containing `secret_key_base: "FAKE-TEST-VALUE"`. Assert that `Index.build` does not return any chunk whose `path` matches `config/dev.exs` and that no chunk contains `"FAKE-TEST-VALUE"`.
  - Place files: `.env`, `.env.local`, `priv/cert/server.pem`, `priv/secrets/foo.exs`, `id_rsa` at root. Assert all are excluded.
  - With `allow_secret_paths: true`, assert the same files are included (sanity check that the opt-in path works).
  - Asserts `Policy.secret_path?/1` is referenced — i.e. removing the call breaks the test.
- New eval case in `test/mr_eric/evals/cases/` (JSON):
  - Workspace fixture contains a `config/dev.exs` with a fake key.
  - Planner is asked a benign question.
  - Eval expectation: `expected_no_secret_leak: true`. Combined with the Section 3 SecretChecker fix, the eval fails if the fake key surfaces in the planner prompt or response.

## Section 3 — `SecretChecker` logic inversion and channel expansion

### Changes

#### 3-1. Sensitive-key handling

- In whichever module ends up owning the scanner (`lib/mr_eric/evals/secret_checker.ex` if present, otherwise extracted from `scorer.ex`):
  - Remove the existing `sensitive_key?/1` *exclusion* path.
  - Add a `sensitive_key?/1` *alert* path: when a map key matches the sensitive-name regex
    `~r/^(api[_-]?key|password|passwd|secret|token|credential|authorization|cookie|session)$/i`,
    inspect the value:
    - empty (`""`, `nil`), `"[REDACTED]"`, or known placeholder (`"<redacted>"`, `"***"`) → OK.
    - otherwise → emit a finding with `reason: :sensitive_key_unredacted`.
  - Continue scanning the value via `flatten_text/1` regardless, so pattern-based detection (`sk-…`, `Bearer …`, AWS-style) still applies on top.

#### 3-2. Channel coverage: allow-list → deny-list

- Replace the current `Map.take(actual, [:final, :trace, :drafts, :reviews, :tool_outputs])` with `Map.drop(actual, @ignored_keys)`, where `@ignored_keys = [:status, :duration_ms, :case_id, :stage_durations]` (pure metadata).
- All remaining fields — including `rag_context`, `changed_files`, `tool_args`, and any future field — are walked via `flatten_text/1`.

#### 3-3. `flatten_text/1` recursion

- Map: recurse into both keys (for `sensitive_key?` checks) and values.
- List / tuple: recurse into each element (tuples via `Tuple.to_list/1`).
- Binary: scan as-is, no trimming.
- Number / atom / pid / reference / port: convert with `to_string/1` where defined; ignore otherwise.
- Structs:
  - "Value-type" structs — `%DateTime{}`, `%Date{}`, `%NaiveDateTime{}`, `%Time{}`, `%Decimal{}` — are stringified via `to_string/1`.
  - Other structs are converted with `Map.from_struct/1` and recursed.

#### 3-4. Result shape

```elixir
defmodule MrEric.Evals.SecretChecker.Result do
  @type finding :: %{
          path: [atom() | binary() | non_neg_integer()],
          reason: :sensitive_key_unredacted | :pattern_match,
          snippet: binary()
        }

  defstruct status: :clean, findings: []
end
```

- `path` is the access path from `actual`'s root, e.g. `[:trace, 3, :payload, :api_key]`. Used for failure messages and tests.
- `snippet` truncates to ~80 chars around the match, with the actual secret already redacted (so the eval report itself does not leak).

#### 3-5. Scorer integration

- `lib/mr_eric/evals/scorer.ex` always runs `SecretChecker.scan/1`, regardless of the `expected_no_secret_leak` flag. Findings always populate the eval report.
- The flag governs the **fail/pass decision**: `true` → any finding fails the case; `false` → findings are reported but do not fail.
- All eval cases under `test/mr_eric/evals/cases/` are migrated to default `expected_no_secret_leak: true` unless they explicitly opt out (none currently should — to be confirmed during implementation).

### Tests

- `test/mr_eric/evals/secret_checker_test.exs`:
  - `payload.password = "sk-real"` → `:leak`, finding path `[:payload, :password]`, reason `:sensitive_key_unredacted` (key alert wins; the pattern would also match).
  - `actual.rag_context = "OPENAI_API_KEY=sk-…"` → `:leak`, finding under `[:rag_context]`.
  - `actual.changed_files = [%{path: "x", diff: "sk-secret"}]` → `:leak`, finding under `[:changed_files, 0, :diff]`.
  - `payload.password = "[REDACTED]"` → `:clean`.
  - `payload.password = nil` → `:clean`.
  - `payload.api_key = "sk-fake"` → `:leak`, reason `:sensitive_key_unredacted`, path `[:payload, :api_key]`.
  - `actual` carrying a `%DateTime{}` does not raise and does not produce findings for the timestamp's stringified form.
- Update existing scorer tests to assert that runs containing leaks always populate `findings` in the result, and that `expected_no_secret_leak: false` still passes the case but reports the leak.

## Section 4 — `shell_command` env allow-list

### Changes

- In `lib/mr_eric/tools/shell_command.ex`:

  ```elixir
  @default_env_allowlist ~w(PATH HOME USER LANG LC_ALL TERM TZ TMPDIR SHELL)
  @default_env_pattern_allowlist [~r/^LC_/]
  ```

- New `build_env/1` constructs the env passed to `System.cmd`:

  ```elixir
  defp build_env(_opts) do
    cfg = Application.get_env(:mr_eric, :shell_env_allowlist, [])
    names = (cfg[:names] || []) |> case do [] -> @default_env_allowlist; v -> v end
    patterns = (cfg[:patterns] || []) |> case do [] -> @default_env_pattern_allowlist; v -> v end

    for {key, value} <- System.get_env() do
      if key in names or Enum.any?(patterns, &Regex.match?(&1, key)) do
        {key, value}
      else
        {key, nil}  # explicit unset — `System.cmd` only removes vars listed with `nil`
      end
    end
  end
  ```

  Empty user-configured lists fall back to the defaults; this prevents an accidentally-empty config from removing `PATH` and breaking every shell command.

- Replace the existing deny-list code (around `lib/mr_eric/tools/shell_command.ex:57-59`) with `env: build_env(opts)` on the `System.cmd` call. Delete the `OPENAI_API_KEY`/`AWS_*` blocklist block.

- Logging:
  - On the first `shell_command` invocation per BEAM boot, `Logger.info("shell_command env allowlist: #{Enum.join(names, ", ")}; patterns: #{...}")`. Use `:persistent_term` to ensure single emission.
  - If any allowlisted name or pattern matches `~r/(?i)(key|token|password|secret|credential)/`, emit `Logger.warning("shell_command env allowlist contains a likely-sensitive name: #{name}")`. Per-boot, single emission.

### Tests

- New file `test/mr_eric/tools/shell_command_env_test.exs`:
  - `System.put_env("FAKE_TOKEN", "leak")`; run `shell_command` with command `printenv` (or `env`, if allowed by Policy — otherwise inject a small wrapper); assert output does not contain `FAKE_TOKEN` or `leak`.
  - `System.put_env("PATH", "/custom/bin")`; run `printenv PATH`; assert output is `/custom/bin`.
  - With `Application.put_env(:mr_eric, :shell_env_allowlist, names: ["FAKE_TOKEN"])`, assert `FAKE_TOKEN` now passes through.
  - With `Application.put_env(:mr_eric, :shell_env_allowlist, names: [])`, assert defaults are used (i.e. `PATH` still passes).
  - Pattern allowlist: with `patterns: [~r/^MR_ERIC_/]`, assert `MR_ERIC_FOO` passes and `OTHER_FOO` does not.

### Documentation

- `README.md` "安全なツール実行" section: add a paragraph describing the allow-list, listing the default names, and showing the `config :mr_eric, :shell_env_allowlist` example.

### Notes / dependencies

- This section assumes `shell_command` continues to use `System.cmd` rather than `:os.cmd` or `Port.open`. The audit's medium-severity finding "use of `sh -lc` (login shell)" is **not** addressed here — that lives in Spec C (tool boundary hardening).
- Spec C will revisit shell invocation more aggressively (drop `sh` entirely in favour of direct `System.cmd(allowlisted_bin, vetted_argv)`), at which point Section 4's `build_env` continues to apply unchanged.

## Risks and follow-ups

- **Random `secret_key_base` per boot in dev/test** invalidates LiveView session cookies on every restart. Acceptable for dev/test ergonomics; flagged in the warning log.
- **Policy.secret_path? sharing** introduces a runtime coupling between `Tools.Policy` and `RAG.Index`. If Policy is later split into its own application, RAG must depend on it explicitly. Tracked but no action required now.
- **Eval case migration**: defaulting `expected_no_secret_leak: true` may cause currently-passing cases to fail if they have latent leaks. Treated as a feature, not a regression — implementation phase will surface any such cases for individual review.
- **`.env` on existing dev machines**: if a developer already has a `.env` file (untracked), the new `.gitignore` line is a no-op for them. The risk is the inverse — a developer who *committed* a personal `.env` before this change. We will run a one-time `git ls-files | grep -E "^\.env"` check during implementation and confirm none are tracked.

## Acceptance criteria

1. `git grep "secret_key_base:" config/` returns no matches outside comments.
2. `Index.build` on this very repository returns zero chunks under `config/`, `priv/cert/`, `priv/secrets/`, or any `.env*` file.
3. `MrEric.Tools.Policy.secret_path?/1` is the **only** definition of "is this path a secret-bearing path" in the codebase.
4. `MrEric.Evals.SecretChecker.scan(%{payload: %{password: "sk-real"}})` returns `%Result{status: :leak, findings: [%{path: [:payload, :password], reason: :sensitive_key_unredacted, ...}]}`.
5. Running `printenv` via `shell_command` after `System.put_env("FAKE_TOKEN", "leak")` does not include `FAKE_TOKEN` in the output.
6. All existing eval cases pass under the new SecretChecker, or any newly-failing case has been triaged and either fixed or explicitly opted out.

## Open questions

None at present — all design decisions resolved during brainstorming. To be re-checked during implementation.
