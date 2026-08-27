# Spec C-1 — Command Argument Grammar Hardening

- **Date:** 2026-08-27
- **Status:** Revision 2 implemented on `main` (2026-08-27). Revision 1's deny-list approach was implemented on `feat/spec-c1-arg-grammar`, reviewed by Codex, and **rejected**: it failed open on every option it did not enumerate. See "Revision 2 — why the deny-list failed".
- **Plan:** `docs/superpowers/plans/2026-08-27-arg-grammar.md`
- **Scope:** Follow-up to Spec C, opened by a Codex review of `feat/spec-c-tool-boundary` and confirmed by direct execution against the branch.
- **Depends on:** Spec C (`Policy.command_argv/1`, argv-direct execution). This spec assumes both are already in `main`.
- **Tracks:** three verified bypasses of the `shell_command` boundary, all pre-existing on `main` and untouched by Spec C.
- **Threat model:** Local single-user dev tool. Protect against a compromised or confused model turning an approved, narrowly-scoped tool call into a wider capability than the user believed they approved. Multi-user authentication is out of scope.

## Background

Spec C removed the shell from approved `shell_command` execution. Its Background argued that under `sh -lc` "the validator and the executor use different parsers", and that removing the shell closes that class of divergence.

That argument was half right. Removing `sh` removed *the shell's* grammar. It did not remove the fact that **every program on the allow-list has an argument grammar of its own**, and `MrEric.Tools.Policy` does not model any of them.

`Policy.validate_command_token_path/2` (`lib/mr_eric/tools/policy.ex:338`) classifies each whitespace-separated token as either "a path" or "not a path". A token that *contains* a path but is not itself one — `-fPATTERNS`, `--git-dir=../store` — takes the `String.contains?(token, "/")` branch and is resolved as if the whole token were a filename. `Path.expand("--git-dir=../store", workspace)` yields `<workspace>/--git-dir=../store`: the `..` sits inside a segment named `--git-dir=..`, which is not the segment `..`, so no parent traversal is detected and the result is inside the workspace. The token is authorized. `git` then reads the same token, splits it at `=`, and resolves `../store` relative to its own cwd — which *is* outside the workspace.

The shell grammar was replaced by N program grammars. Spec C's own Risks table did not anticipate this, and its acceptance criteria could not have caught it: every criterion holds, and the bypasses still work.

### Verified bypasses

All three were executed against `feat/spec-c-tool-boundary` at commit `88cc83d` via `MrEric.Tools.ShellCommand.run/2` with a temp `workspace_root`. All three reached the program and produced the effect described.

| # | Command | `authorize/3` | Actual effect |
|---|---------|---------------|---------------|
| 1 | `sed -E -i.bak s/foo/bar/ README.md` | `{:ok, approval_required?: true}` | **Wrote to `README.md` in place** (`"foo\n"` → `"bar\n"`), bypassing `apply_patch`, `PatchValidator`, and the entire approval/diff flow |
| 2 | `grep -f<absolute-path-outside-workspace> needle.txt` | `{:ok, approval_required?: true}` | **exit 0** — read a file outside the workspace and matched against it |
| 3 | `git --git-dir=../gitstore --work-tree=../outside status --short` | `{:ok, approval_required?: true}` | **exit 0, printed `?? SECRET.txt`** — enumerated a directory tree outside the workspace |

Three distinct sub-causes, one root cause.

**1. Option-attached paths are invisible to the path check.** Both `-fPATH` (attached value, POSIX short option) and `--opt=PATH` (attached value, GNU long option) hide a path inside a token that expands to a harmless-looking in-workspace string. `embedded_absolute_path/1` (`lib/mr_eric/tools/policy.ex:364`) already tries to catch one shape of this — its regex is `~r/(?:^|=)(\/[^=\s]+)/`, which requires the path to start the token or follow an `=`. `-f/etc/passwd` matches neither: the `/` follows `f`. And nothing at all catches a *relative* attached path like `--git-dir=../store`.

**2. `@dangerous_command_patterns` matches by adjacency, not by option set.** The `sed` rule is `~r/(^|\s)sed\s+-i/`. It fires on `sed -i.bak ...` and misses `sed -E -i.bak ...` — any option between the program and `-i` defeats it. The deny-list is positional where it needs to be set-based. `sed -i` is the only *mutating* option on the allow-list today, which is precisely why it must not be defeatable by reordering.

**3. There is no per-program option allow-list.** `Policy` allow-lists program *names* (`~w(pwd ls cat sed grep rg git)`) and, for `git`, subcommands (`~w(status diff log show)`). It says nothing about options. `git status` is a read-only subcommand, but `git --git-dir=X --work-tree=Y status` re-points what "the repository" means before the subcommand runs. `git -c core.fsmonitor=<cmd> status` is worse: `-c` sets config that can name a program to execute. The subcommand allow-list is doing less work than its name suggests.

### What is *not* broken

Two claims from the same review did not survive verification, and are recorded here so a future reader does not re-open them.

- **`Path.basename(program)` vs. the executed path.** `ensure_allowed_shell_command/1` allow-lists `Path.basename(program)` while `ShellCommand.run/2` passes the original `program` to `System.find_executable/1`. This is a real validate-vs-execute mismatch and Section 3 closes it — but it is **not** currently exploitable. Erlang's `os:find_executable/1` resolves a *relative* name by joining it onto each `PATH` entry, never onto the process cwd, so `tmp/pwd` cannot resolve to a workspace binary. Absolute program paths are already rejected by `embedded_absolute_path/1`. Note also that the pre-Spec-C code (`sh -lc` with `cd: workspace`) *did* execute `tmp/pwd` from the workspace; Spec C improved this.
- **`ApplyPatch.apply_validated/2` being public.** `@doc false` hides a function from docs, not from callers, so a hand-built proposal map can reach the write path without `PatchValidator`. This is exactly the test seam Spec C's plan specified, it has no production caller, and closing it costs a public-API change for no verified attack. Left as-is deliberately; revisit only if a second caller appears.

## Revision 2 — why the deny-list failed

Revision 1 specified, under Non-Goals, "a conservative **allow-list of options** … **anything unrecognised is rejected**". What got implemented was the opposite: two deny-list maps (`@mutating_options`, `@root_repointing_options`) consulted with `Map.get(program, [])`, so an unenumerated option — or any option of an unenumerated program — carried no restriction at all. A Codex review of the implementation branch found the gap, and every case below was then re-executed independently through `MrEric.Tools.ShellCommand.run/2` against a temp `workspace_root`.

| Command | Result | Effect |
|---------|--------|--------|
| `rg --pre=./pre_hook needle inside.txt` | ALLOWED exit 0 | **Executed an arbitrary child process** — the hook ran and wrote its marker |
| `git --config-env=core.pager=X status` | ALLOWED | Passed the gate (exit 128 only because the named env var was unset) |
| `sed -Ei.bak s/foo/bar/ inside.txt` | ALLOWED exit 0 | **Rewrote the file**, `.bak` created |
| `sed -ni.bak s/foo/bar/p inside.txt` | ALLOWED exit 0 | **Rewrote the file** |
| `grep -nf../outside/patterns inside.txt` | ALLOWED exit 0, `2:needle` | **Read outside the workspace** |
| `rg -nf../outside/patterns inside.txt` | ALLOWED exit 0, `2:needle` | **Read outside the workspace** |
| `sed -nf../outside/sed_script inside.txt` | ALLOWED exit 0, `OUTSIDE_SCRIPT` | Executed an external sed script |
| `sed -n 1w../outside/marker inside.txt` | ALLOWED exit 0 | **Wrote outside the workspace** |
| `git diff --output=target.txt` | ALLOWED exit 0 | **Truncated a file** (`KEEP-ME` → empty) |
| `rg -L OUTSIDE_ONLY .` | ALLOWED exit 0 | Followed a symlink out of the workspace |

Three distinct implementation faults, one architectural one.

**a. Bundled short options defeat token-level regexes.** `@mutating_options` matched `~r/^-{1,2}i/` against whole tokens, so it saw `-i` but not the `i` inside `-Ei` or `-ni`. POSIX short options bundle; any check that reads a token as an opaque string will keep missing them.

**b. `option_value_paths/1` guessed the option name.** It took the *first letter* as the name and everything after it as the value, so `-nf../outside/patterns` yielded the value `f../outside/patterns`, which `Path.expand/2` resolved to `<workspace>/f../outside/patterns` — inside the workspace, because the `..` sits inside a segment named `f..`. The path check then passed. Extracting a value requires knowing the option's **arity**, which requires knowing the program.

**c. It also mis-classified values that are not paths.** `-e` and `--regexp` carry a *pattern*; `--color` carries a literal. Resolving them as paths rejected `grep -e/etc/passwd`, `grep --regexp=/etc/passwd`, and `grep -- -f../needle` — all legitimate. The same stage never modelled `--`, so option parsing did not stop where it should.

**d. Architecturally, a deny-list of dangerous options can never be finished.** `rg --pre` and `rg --hostname-bin` name a program to run. `git --config-env` and `git -c` set config that can name a program to run. `git --output` writes. `rg -L` and `ls -L` follow symlinks out. `sed`'s script language has `w` (write), `r` (read), and `e` (execute) commands, plus `-f` to load a script from a file. Each of these had to be discovered one at a time, and the next one is always unenumerated.

Revision 2 therefore inverts the check, as Revision 1's own Non-Goals said it should: **a per-program grammar that allow-lists options by name and arity, classifies each value as a path, a pattern, or a literal, and rejects everything it does not recognise.**

`sed` is **removed from `@allowed_shell_commands`.** It is not an option-flag problem: `sed` is a scripting language whose scripts can read, write, and (GNU) execute, so bounding it means parsing sed scripts. `grep` and `rg` cover the read-oriented use cases the allow-list exists for. This narrows the allow-list; Spec C's constraint was against *widening* it.

Ordering is not implicated. `ensure_safe_command/1` → option gate → path resolution runs in a single `with`, and an early refusal stops the command outright. The defect was classification, not sequence.

## Goals

1. An option is accepted only if the program's grammar names it. Unknown option, unknown program → refused.
2. A value is resolved as a path only when the grammar says that option takes a path — arity-correct, bundle-aware, and identical for attached and separated forms.
3. A value that is a pattern or a literal is never resolved as a path.
4. `--` stops option parsing; operand position decides pattern vs. path.
5. The program token is a bare allow-listed name, so the string that was checked is the string that is executed.
6. All of the above hold for `ShellCommand.run/2` called directly, not only through `Executor`.

## Non-Goals

- **Completeness of each program's real grammar.** The tables are deliberately small. An option nobody uses is better absent than guessed at — absence is refusal, and refusal is recoverable (the model retries a simpler form).
- **Keeping `sed`.** Removed from the allow-list; see Revision 2.
- **Widening `@allowed_shell_commands`.** It only narrows.
- **Modifying `@forbidden_shell_syntax` or `@dangerous_command_patterns`.** They stay byte-identical and act as the first-pass string filter.
- **Process sandboxing**, and **closing the residual `apply_patch` write race**. Both out of scope, as in Spec C.

## Architecture overview

One table and one walker replace three ad-hoc stages. No new modules, no schema changes, no result-shape changes.

```
authorize(:shell_command, args, opts)
  |
  |- normalize_command/1                (unchanged)
  |- ensure_safe_command/1
  |    |- @forbidden_shell_syntax       (unchanged -- first-pass string filter)
  |    |- @dangerous_command_patterns   (unchanged -- first-pass string filter)
  |    `- ensure_allowed_shell_command/1 (bare program name; program must have a grammar)
  `- ensure_argv_allowed/2              (NEW: the grammar walker; replaces
                                          ensure_program_options_allowed/1,
                                          ensure_command_paths_allowed/2,
                                          validate_command_token_path/2,
                                          option_value_paths/1,
                                          embedded_absolute_path/1,
                                          git_subcommand/1)
```

The string deny-lists stay as a cheap first pass. They are belt to the grammar's braces, and Spec C's constraint keeps them byte-identical.

`ensure_argv_allowed/2` is the only thing that resolves a path from a command. That is the point: a token is checked as a path **because the grammar says that option takes a path**, not because it happens to contain a `/`. Both Revision 1 faults (b) and (c) disappear as a class.

### The grammar table

Each program maps to `%{short: %{...}, long: %{...}, operands: ...}`.

- `short` keys are **single characters**, so bundles decompose correctly. Values are `:flag` (no argument), or `:path` / `:pattern` / `:literal` (takes an argument, attached or as the next token).
- `long` keys are full `--names`. Same value kinds.
- `operands` is `:none`, `:paths`, `:pattern_then_paths` (the first bare operand is a pattern unless one already arrived via `-e`/`-f`), or `{:subcommand, table}` for `git`.

```elixir
@program_grammar %{
  "pwd" => %{short: %{"P" => :flag, "L" => :flag}, long: %{}, operands: :none},

  "cat" => %{short: %{"n" => :flag, "b" => :flag, "s" => :flag},
             long: %{}, operands: :paths},

  "ls"  => %{short: %{"1" => :flag, "a" => :flag, "A" => :flag, "l" => :flag,
                      "h" => :flag, "r" => :flag, "t" => :flag, "S" => :flag,
                      "F" => :flag, "d" => :flag, "p" => :flag, "R" => :flag,
                      "G" => :flag},
             long: %{"--color" => :literal}, operands: :paths},
  # NB: `-L` (dereference symlinks) is absent on purpose.

  "grep" => %{short: %{... "e" => :pattern, "f" => :path,
                       "m" => :literal, "A" => :literal, ...},
              long:  %{"--regexp" => :pattern, "--file" => :path,
                       "--color" => :literal, ...},
              operands: :pattern_then_paths},

  "rg"  => %{short: %{... "e" => :pattern, "f" => :path, "g" => :literal, ...},
             long:  %{"--version" => :flag, "--regexp" => :pattern,
                      "--file" => :path, "--glob" => :literal, ...},
             operands: :pattern_then_paths},
  # NB: `--pre`, `--hostname-bin`, `-L`, `--follow` are absent on purpose.

  "git" => %{short: %{"C" => :path}, long: %{"--no-pager" => :flag},
             operands: {:subcommand, @git_subcommands}}
}
```

`@allowed_shell_commands` becomes `~w(pwd ls cat grep rg git)` — `sed` removed — and a compile-time assertion pins it to `Map.keys(@program_grammar)` so the two cannot drift.

`grep` keeps `-L` (files-without-match, harmless) while `rg` and `ls` do not (follow-symlinks). Per-program tables are what make that distinction expressible; a global deny-list could not.

`@git_subcommands` covers `status`, `diff`, `log`, `show`, each with its own conservative flag set. `--output` is absent from `diff`, `-c` and `--config-env` are absent from the git globals, and `--git-dir` / `--work-tree` / `--exec-path` / `--namespace` are absent by construction — nothing needs to name them, because absence *is* rejection now.

### The walker

```
walk(tokens, grammar, state):
  "--"          -> every remaining token is an operand
  "-"           -> stdin, skip
  "--name[=v]"  -> look up in grammar.long; unknown => :dangerous_command
                   :flag with an attached value => :dangerous_command
                   otherwise take v (attached, else next token) and classify
  "-abc..."     -> walk the bundle left to right:
                     :flag            => continue to the next character
                     value-taking     => the rest of the bundle is the value,
                                         or the next token when the bundle ends
                     unknown          => :dangerous_command
  operand       -> per grammar.operands
```

Classification:

| Kind | Check |
|------|-------|
| `:path` | `Policy.resolve_workspace_path/2` — containment, symlink-segment walk, `secret_path?/1` |
| `:pattern` | none — it is a regex, never opened |
| `:literal` | none — enumerated case by case, and only where an unchecked value is safe (`--color=auto`, `-m 5`, `--glob`) |

A missing value for a value-taking option is `{:error, :invalid_args}`.

## Section 1 — Bundled short options and arity-correct value extraction

Fixes Revision 1 faults (a) and (b).

Because `short` is keyed by single characters, `-Ei.bak` decomposes to `E` (flag) then `i` — and `i` is simply not in `sed`'s table, because `sed` no longer has a table. For `grep`, `-nf../outside/patterns` decomposes to `n` (flag) then `f` (`:path`) with value `../outside/patterns`, which `resolve_workspace_path/2` rejects. The value is the *actual* value, not a guess.

### Tests

1. `grep -nf../outside/patterns needle.txt` → `{:error, :outside_workspace}`
2. `grep -f../outside/patterns needle.txt` → `{:error, :outside_workspace}` (unbundled, Revision 1 regression guard)
3. `grep --file=../outside/patterns needle.txt` → `{:error, :outside_workspace}`
4. `grep -f ../outside/patterns needle.txt` → `{:error, :outside_workspace}` (separated value)
5. `rg -nf../outside/patterns needle.txt` → `{:error, :outside_workspace}`
6. `grep -rn needle lib` → `{:ok, ...}` (regression guard)
7. `grep -f` with no value → `{:error, :invalid_args}`

## Section 2 — Unknown options and unknown programs are refused

Fixes Revision 1 fault (d).

`Map.fetch/2` on the grammar, with `:error` mapped to `{:error, :dangerous_command}`, is the whole mechanism. Nothing has to be listed as dangerous.

### Tests

1. `rg --pre=./hook needle f.txt` → `{:error, :dangerous_command}`, **and no child process runs**
2. `rg --hostname-bin=./hook needle f.txt` → `{:error, :dangerous_command}`
3. `rg -L OUTSIDE .` → `{:error, :dangerous_command}`
4. `ls -LR .` → `{:error, :dangerous_command}`
5. `git --config-env=core.pager=X status` → `{:error, :dangerous_command}`
6. `git diff --output=target.txt` → `{:error, :dangerous_command}`, **and the target file is unchanged**
7. `sed -n 1,5p README.md` → `{:error, :dangerous_command}` (`sed` is off the allow-list)
8. `sed -Ei.bak s/foo/bar/ README.md` → `{:error, :dangerous_command}`, **and the file is unchanged**
9. `rg --version` → `{:ok, ...}` (regression guard — an enumerated long flag)

## Section 3 — Value kinds, `--`, and operands

Fixes Revision 1 fault (c).

A pattern is never resolved as a path, `--` stops option parsing, and operand position determines whether a bare token is a pattern or a path.

### Behaviour deltas from Revision 1

- `grep -e/etc/passwd f.txt` → `{:ok, ...}` (was wrongly `:outside_workspace`; `/etc/passwd` here is a regex)
- `grep --regexp=/etc/passwd f.txt` → `{:ok, ...}` (same)
- `grep -- -f../needle f.txt` → `{:ok, ...}` — after `--`, `-f../needle` is the pattern operand
- `grep pattern /etc/passwd` → `{:error, :outside_workspace}` — operand after the pattern is a path

### Tests

1. `grep -e/etc/passwd needle.txt` → `{:ok, ...}`
2. `grep --regexp=/etc/passwd needle.txt` → `{:ok, ...}`
3. `grep -- -f../needle needle.txt` → `{:ok, ...}`
4. `grep needle /etc/passwd` → `{:error, :outside_workspace}`
5. `cat -- note.txt` → `{:ok, ...}`
6. `ls --color=auto` → `{:ok, ...}` (regression guard)
7. `pwd -P` → `{:ok, ...}`; `pwd extra` → `{:error, :dangerous_command}` (`operands: :none`)
8. `git -C sub status --short` → `{:ok, ...}` (regression guard, pins that `-C` takes a path)
9. `git status --short` → `{:ok, ...}` (regression guard)

## Section 4 — What is *not* addressed, and why

- **A recursive search can read a secret file *inside* the workspace.** `Policy.secret_path?/1`
  only reaches paths that appear as command tokens; it has no reach into a program's own
  directory walk. So `cat .env` is refused as `:secret_file` while `grep -rn AKIA .` returns
  `./.env:1:AKIA...` — the same bytes. Measured, not theoretical.

  Half of this is closed. `rg` skips hidden and gitignored files by default, and the two
  options that defeat that default — `--hidden` and `-u` / `--unrestricted` — are absent from
  the grammar, so `rg <term> .` does not read `.env`. They exist for no other purpose, so
  removing them costs nothing.

  The `grep -r` half is **accepted, not fixed.** `grep -rn needle lib` is the canonical use of
  the allow-list and dropping `-r` would gut it; output post-filtering by `secret_path?/1` only
  works for the spellings that prefix a filename (`-n`/`-H`) and silently misses `-h`, binary
  matches, and `--null`. The exposure is bounded: it stays inside the workspace, so no
  outside-workspace criterion is affected, and `shell_command` still requires per-call
  approval. `test/mr_eric/tools/shell_command_test.exs` pins the asymmetry in both directions —
  `rg` must not read `.env`, `grep -r` may — so a future change to the boundary shows up as a
  test failure rather than as a silent drift.

- **`grep -rn token .` → `:secret_file`.** A bare operand matching `secret|credential|token` is refused because `secret_path?/1` is applied to it. This predates Spec C entirely and the bare-operand path is unchanged here. It is over-rejection of a *search term*, and fixing it means narrowing `secret_path?/1` for operands, which touches RAG's use of the same function. Left alone deliberately; note it if it becomes annoying in practice.
- **The residual `File.write!/2` race in `apply_patch`.** Unchanged from Spec C; Erlang exposes no `O_NOFOLLOW`.
- **Process sandboxing.** A program that legitimately reads a workspace file can still do whatever its own binary permits.
- **`ApplyPatch.apply_validated/2` being public.** Deliberate test seam, no production caller. See Revision 1's "What is *not* broken".

## Risks and follow-ups

| Risk | Mitigation |
|------|------------|
| The grammar is too small and refuses something the model legitimately wants | Correct failure direction, and cheap to widen one entry at a time with a test. Every refusal has a simpler permitted equivalent. The regression-guard set is what proves the common forms still work. |
| Losing `sed` breaks a workflow | `sed` was read-*and-write*; the read-only half is covered by `grep`/`rg`. Only one existing test used it, and it becomes a rejection test. Golden cases use `pwd` only. |
| A `:literal` value turns out to be path-like for some option | Literals are enumerated one option at a time, never by default. If a future entry's value can name a file, classify it `:path`. |
| The walker mis-parses a bundle and silently allows something | Every table entry is exercised by a test, and the bypass table from Revision 2 is pinned end-to-end with effect assertions (file unchanged, no child process, nothing read from outside). |
| Someone re-adds a program without a grammar | `@allowed_shell_commands` is pinned to `Map.keys(@program_grammar)` by a compile-time assertion, so a program with no grammar fails the build. |
| `grep -rn token .` is still refused as `:secret_file` | Pre-existing, documented in Section 4, deliberately untouched. |

Follow-ups explicitly left elsewhere:

- Process sandboxing for the child — no spec owns this yet.
- `max_children` and trace/history caps — **Spec D**.

## Acceptance criteria

Every row of the Revision 2 bypass table, re-run through `ShellCommand.run/2`, must refuse **and** show no effect:

1. `rg --pre=./hook …` and `rg --hostname-bin=./hook …` → `:dangerous_command`, and the hook's marker file does **not** exist.
2. `sed …` in any form → `:dangerous_command`; the target file is byte-identical and no `.bak` is created.
3. `grep -nf<outside>`, `rg -nf<outside>`, and their unbundled, `--file=`, and separated-value forms → `:outside_workspace`.
4. `git --config-env=…`, `git -c …`, `git --git-dir=…`, `git --work-tree=…`, `git diff --output=…` → `:dangerous_command`; the `--output` target is byte-identical.
5. `rg -L …` and `ls -LR …` → `:dangerous_command`.
6. `rg --hidden`, `rg -u`, `rg -uu`, `rg --unrestricted` → `:dangerous_command`, and
   `rg <term> .` does not report a match inside `.env`.
7. Over-rejection is gone: `grep -e/etc/passwd f.txt`, `grep --regexp=/etc/passwd f.txt`, and `grep -- -f../needle f.txt` all return `{:ok, %{approval_required?: true}}`.
8. The common forms still work: `pwd`, `pwd -P`, `ls -la`, `ls --color=auto`, `cat note.txt`, `cat -n note.txt`, `grep -rn needle lib`, `rg --version`, `git status --short`, `git -C sub status --short`, `git diff --stat`.
9. `@allowed_shell_commands` is `~w(pwd ls cat grep rg git)` and equals `Map.keys(@program_grammar)`; `@forbidden_shell_syntax` and `@dangerous_command_patterns` are byte-identical to their Spec C state.
10. The `shell_command` schema, the approval-request map, and every tool result shape are unchanged. `priv/evals/phase9_golden_cases.json` is unmodified and `mix mr_eric.evals` passes.
11. `mix precommit` passes.

## Out of scope (tracked elsewhere)

- Spec D — Run lifetime and resources (`max_children`, trace/history caps)
- Spec E — eval/RAG correctness (scorer early-pass, RAG cache, `rag_default_index` golden case)
- Spec F — production HTTP (`force_ssl`, HSTS, CSP, `PHX_HOST` hard-fail)
- Ecto/DB persistence, login and multi-user auth, `git commit`/`push`/`reset`/`clean`, force push, automatic rollback — permanently out of scope for this project.
