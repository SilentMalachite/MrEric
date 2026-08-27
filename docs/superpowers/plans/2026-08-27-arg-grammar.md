# Spec C-1 — Command Argument Grammar Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close three verified `shell_command` bypasses that survive Spec C: option-attached paths (`-fPATH`, `--opt=PATH`) escaping the workspace check, `sed -i` evading its deny-list rule by option reordering, and `git --git-dir`/`--work-tree`/`-c` re-pointing what the repository is.

**Architecture (Revision 2):** `MrEric.Tools.Policy` gains a per-program grammar table (`@program_grammar`) and one walker (`ensure_argv_allowed/2`) that parses the argv vector against it. An option is accepted only if the table names it; a value is resolved as a path only if the table says that option takes one. The walker replaces `ensure_program_options_allowed/1`, `ensure_command_paths_allowed/2`, `validate_command_token_path/2`, `option_value_paths/1`, `embedded_absolute_path/1`, and `git_subcommand/1`. `sed` is removed from `@allowed_shell_commands`. `@forbidden_shell_syntax` and `@dangerous_command_patterns` keep their exact Spec C contents as a first-pass string filter.

**Tech Stack:** Elixir 1.17, Phoenix 1.8, ExUnit. No new dependencies. No changes to tool schemas, result shapes, or the approval-request map.

**Spec:** `docs/superpowers/specs/2026-08-27-arg-grammar-design.md`

**Depends on:** Spec C in `main` (`Policy.command_argv/1`, argv-direct execution in `ShellCommand.run/2`).

## Global Constraints

- **Respond to the user in Japanese**, leading with the conclusion (`CLAUDE.md`).
- **At most 3 files per commit.** Every task below is sized to respect this. Do not batch tasks into one commit.
- **`mix precommit` is the gate.** It runs `compile --warning-as-errors` + `deps.unlock --unused` + `test` in `:test` env.
- **Do not widen `@allowed_shell_commands`.** Revision 2 *narrows* it to `~w(pwd ls cat grep rg git)` by removing `sed`. Never add to it.
- **Do not modify `@forbidden_shell_syntax` or `@dangerous_command_patterns`.** All new coverage goes in the grammar, not the string deny-lists. Acceptance criterion 8 checks this.
- **Never use `Map.get(table, key, [])` for a security decision.** That default is exactly what made Revision 1 fail open. Use `Map.fetch/2` and map `:error` to a refusal.
- **A `:literal` value kind is an assertion that an unchecked value is safe for that option.** Default to `:path` when unsure.
- **Do not modify `priv/evals/phase9_golden_cases.json`.** Acceptance criterion 7.
- **Every regression-guard test in this plan is load-bearing.** The failure mode of this spec is over-rejection; the guards are what detect it. Do not delete one to make a task pass.
- **Adding a program to `@allowed_shell_commands` later requires a `@mutating_options` / `@root_repointing_options` entry** or a written argument for why none is needed. Record that in the moduledoc.

---

## File Structure

| Path | Disposition | Responsibility |
|------|-------------|----------------|
| `lib/mr_eric/tools/policy.ex` | modify | `@program_grammar`, `@git_subcommands`, `ensure_argv_allowed/2`; delete the Revision 1 stages |
| `test/mr_eric/tools/policy_test.exs` | modify | Decision-level cases per section plus the regression-guard set |
| `test/mr_eric/tools/shell_command_test.exs` | modify | End-to-end cases proving the *effect* is prevented, not just the decision |
| `docs/superpowers/README.md` | modify | Mark Spec C-1 implemented; point "次にやる作業" at Spec D |
| `CLAUDE.md` | modify | Record the argument-grammar boundary |
| `CHANGELOG.md` | modify | Security entry for Spec C-1 |

`Policy` still owns *what is allowed*; the tools still own *doing the allowed thing*. This plan only deepens what `Policy` inspects.

---

## Task 1: Reproduce every Revision 2 bypass as a failing end-to-end test

The Revision 1 branch already carries four such cases. This task adds the ones its review found, and they assert on **effects** — file bytes, marker files, leaked output — because a return value alone would not have caught Revision 1.

**Files:**
- Modify: `test/mr_eric/tools/shell_command_test.exs`

- [ ] **Step 1: Extend the `describe "argument grammar boundary (Spec C-1)"` block**

Add cases for: `rg --pre=./hook` (assert the hook's marker file does **not** exist), `rg --hostname-bin`, `sed -Ei.bak` and `sed -ni.bak` (assert file bytes unchanged and no `.bak`), `sed -nf<outside script>`, `sed -n 1w<outside path>` (assert the outside file was **not** created), `grep -nf<outside>`, `rg -nf<outside>`, `git --config-env=`, `git diff --output=<file>` (assert the target's bytes unchanged), `rg -L`, `ls -LR`.

Build the hook as a `#!/bin/sh` script that writes a marker outside the workspace, `File.chmod!(hook, 0o755)`. Assert on the marker, not on output — output can be empty for reasons unrelated to the boundary.

**Isolate every case.** Revision 1's own probe was contaminated: an earlier `sed -ni.bak` rewrote the fixture, so a later `grep -nf` reported exit 1 and looked blocked when it was not. One fresh workspace per test.

- [ ] **Step 2: Run and confirm each fails for the documented reason**

Run: `mix test test/mr_eric/tools/shell_command_test.exs`

Expected: every new case FAILS with `right: {:ok, ...}`, matching the Revision 2 table. If one is already refused, check *why* before moving on — Revision 1 refused `git --git-dir=<absolute>` for a path reason that did not generalise.

- [ ] **Step 3: Commit the red tests**

```bash
git add test/mr_eric/tools/shell_command_test.exs
git commit -m "test(shell_command): reproduce the Revision 2 argument-grammar bypasses"
```

---

## Task 2: Introduce the grammar table and the walker

**Files:**
- Modify: `lib/mr_eric/tools/policy.ex`
- Modify: `test/mr_eric/tools/policy_test.exs`

- [ ] **Step 1: Write the decision-level tests**

Replace the Revision 1 `describe` blocks (`"option-attached paths"`, `"mutating options"`, `"root-repointing options and bare program names"`) with blocks matching spec Sections 1–3. Carry over every case that is still correct; **delete** the three that encoded the over-rejection (`grep -e/etc/passwd`, `grep --regexp=/etc/passwd`, `grep -- -f../needle` asserting `:outside_workspace`) and re-add them asserting `{:ok, ...}`.

The regression-guard set is load-bearing and must include at least: `pwd`, `pwd -P`, `ls -la`, `ls --color=auto`, `cat note.txt`, `cat -n note.txt`, `grep -rn needle lib`, `rg --version`, `git status --short`, `git -C sub status --short`, `git diff --stat`.

- [ ] **Step 2: Run to confirm they fail**

- [ ] **Step 3: Implement**

Add `@program_grammar` and `@git_subcommands` per the spec. Narrow `@allowed_shell_commands` to `~w(pwd ls cat grep rg git)` and pin it:

```elixir
  @compile_assert_grammar Enum.sort(Map.keys(@program_grammar)) == Enum.sort(@allowed_shell_commands) ||
                            raise "grammar and allow-list drifted"
```

Write `ensure_argv_allowed/2` as the spec's walker. Use `Map.fetch/2`, never `Map.get/3` with a default. Delete `ensure_program_options_allowed/1`, `ensure_command_paths_allowed/2`, `validate_command_token_path/2`, `validate_plain_token_path/2`, `option_value_paths/1`, `embedded_absolute_path/1`, `@mutating_options`, `@root_repointing_options`, and `git_subcommand/1`. Keep `command_argv/1`, `command_tokens/1`, `clean_command_token/1`, and `secret_path?/1` unchanged.

Re-point the pipeline:

```elixir
    with {:ok, command} <- normalize_command(command),
         :ok <- ensure_safe_command(command),
         :ok <- ensure_argv_allowed(command, opts) do
```

- [ ] **Step 4: Run the policy tests**

- [ ] **Step 5: Run the end-to-end tests** — all Task 1 cases must be green, with their effect assertions.

- [ ] **Step 6: Commit**

```bash
git add lib/mr_eric/tools/policy.ex test/mr_eric/tools/policy_test.exs
git commit -m "fix(policy): replace the option deny-list with a per-program grammar allow-list"
```

---

## Task 3: Fix the fallout from removing `sed`

**Files:**
- Modify: `test/mr_eric/tools/policy_test.exs` (or wherever `sed` cases live)
- Modify: `test/mr_eric/tools/shell_command_test.exs` if needed

- [ ] **Step 1:** `test "still allows read-only sed"` asserting `sed -n 1,5p README.md` → `{:ok, ...}` must become a rejection case. Search the suite for every other `sed` usage and re-point it.

- [ ] **Step 2:** Run `mix test` and `mix mr_eric.evals`. Golden cases use `pwd` only, so evals must pass unmodified.

- [ ] **Step 3: Commit**

---

## Task 4: Full verification

- [ ] Re-run the Revision 2 bypass table end-to-end and confirm every effect assertion.
- [ ] Confirm `@forbidden_shell_syntax` / `@dangerous_command_patterns` are byte-identical to `main` (extract-and-diff, not `git diff | grep` — the grep hits comments).
- [ ] `mix precommit`, `mix test`, `mix mr_eric.evals`, `git status --short priv/evals/`.

---

## Task 5: Documentation sync

**Files:** `docs/superpowers/README.md`, `CLAUDE.md`, `CHANGELOG.md`

Record the grammar allow-list, the removal of `sed`, and — in the changelog — that Revision 1's deny-list shipped nothing and why, so the failure mode is on the record.

---

## Verification checklist

| # | Command | Expected |
|---|---------|----------|
| 1 | `mix test test/mr_eric/tools/shell_command_test.exs` | PASS — every effect assertion included |
| 2 | `mix test test/mr_eric/tools/policy_test.exs` | PASS — bypasses refused, regression guards `{:ok, ...}` |
| 3 | `grep -n 'Map.get(@' lib/mr_eric/tools/policy.ex` | no output — no fail-open default survives |
| 4 | `grep -n '"sed"' lib/mr_eric/tools/policy.ex` | no output |
| 5 | attribute extract + `diff` vs `main` | `@forbidden_shell_syntax` / `@dangerous_command_patterns` unchanged |
| 6 | `git status --short priv/evals/` then `mix mr_eric.evals` | no modified golden cases; evals PASS |
| 7 | `mix test` | PASS |
| 8 | `mix precommit` | PASS |
