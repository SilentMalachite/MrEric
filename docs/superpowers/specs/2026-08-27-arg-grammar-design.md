# Spec C-1 — Command Argument Grammar Hardening

- **Date:** 2026-08-27
- **Status:** Designed. Not yet implemented.
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

## Goals

1. A path carried inside an option token is resolved through `Policy.resolve_workspace_path/2`, whatever its attachment syntax.
2. Mutating options are rejected regardless of their position in the argv vector.
3. Options that re-point a program's notion of its own root or that can name a program to execute are rejected per-program.
4. The program token is a bare name, so the string that was allow-listed is the string that gets resolved and executed.
5. All four hold for `ShellCommand.run/2` called directly, not only through `Executor`.

## Non-Goals

- **Modelling each program's full grammar.** The aim is a conservative allow-list of options, not a parser for `git`. Anything unrecognised is rejected.
- **Widening `@allowed_shell_commands`.** It stays `~w(pwd ls cat sed grep rg git)`.
- **Process sandboxing.** A program that legitimately reads a workspace file can still do anything else its own binary permits. Out of scope, as in Spec C.
- **Closing the residual `File.write!/2` race.** Unchanged from Spec C: Erlang exposes no `O_NOFOLLOW`.
- **Retrofitting `main`'s history.** These are pre-existing defects; this spec fixes them forward.

## Architecture overview

One new private stage inside `Policy`, and two tightened existing ones. No new modules, no schema changes, no result-shape changes.

```
authorize(:shell_command, args, opts)
  |
  |- normalize_command/1                 (unchanged)
  |- ensure_safe_command/1
  |    |- @forbidden_shell_syntax        (unchanged)
  |    |- @dangerous_command_patterns    (unchanged -- see Section 2 on why)
  |    `- ensure_allowed_shell_command/1 (TIGHTENED: bare program name only)
  |- ensure_program_options_allowed/1    (NEW: per-program option allow-list)
  `- ensure_command_paths_allowed/2
       `- validate_command_token_path/2  (TIGHTENED: extract option-attached values)
```

`ensure_program_options_allowed/1` is a new step rather than more entries in `@dangerous_command_patterns`, because the deny-list operates on the raw command *string* and this check needs the *argv vector* — the same vector `command_argv/1` already produces and `ShellCommand` already executes. Set-based reasoning on argv is what makes sub-cause 2 fixable at all.

Spec C's constraint "do not touch `@forbidden_shell_syntax` or `@dangerous_command_patterns`" is preserved literally: both attributes keep their current contents. The new coverage is added alongside them, on the argv vector, where it can be positional-order-independent.

## Section 1 — Option-attached path extraction

### Changes

Add a private helper that, given a token, returns every path-like value it carries:

```elixir
# `-fPATTERNS`, `--file=PATTERNS`, `--git-dir=../store`
defp option_value_paths(token)
```

Rules, deliberately conservative:

- If the token does not start with `-`, it is not an option; return `[]` and let the existing branches handle it as a bare path.
- If the token is `--opt=VALUE`, return `[VALUE]` when `VALUE` is non-empty.
- If the token is `-XVALUE` where `X` is a single letter and `VALUE` is non-empty, return `[VALUE]`.
- Otherwise return `[]`.

Then rewrite `validate_command_token_path/2` so the option branch runs *before* the existing path branches:

```elixir
defp validate_command_token_path(token, opts) do
  case option_value_paths(token) do
    [] -> validate_plain_token_path(token, opts)
    values -> Enum.reduce_while(values, :ok, &validate_option_value(&1, &2, opts))
  end
end
```

`validate_option_value/3` applies the same rules `validate_plain_token_path/2` applies today — `://` passthrough, `..` rejection, absolute/relative resolution through `resolve_workspace_path/2`, `secret_path?/1` — to the extracted value.

`embedded_absolute_path/1` becomes redundant for the `=` shape it currently covers and is folded into `option_value_paths/1`. It is kept for bare tokens that embed an absolute path with no option prefix.

### Behaviour deltas

- `grep -f../outside/p f.txt` and `grep -f/etc/passwd f.txt` → `{:error, :outside_workspace}` (was `{:ok, ...}`).
- `git --git-dir=../store status` → `{:error, :outside_workspace}` (was `{:ok, ...}`); also independently rejected by Section 3.
- `ls --color=auto` → still `{:ok, ...}`. `auto` is not path-like, resolves inside the workspace, and is not secret. This is the case that must not regress.
- `grep -e foo f.txt` → unchanged; `-e` and `foo` are separate tokens and `foo` has no `/`.

### Tests

New `describe "option-attached paths (Spec C-1)"` in `test/mr_eric/tools/policy_test.exs`:

1. `grep -f../outside/patterns needle.txt` → `{:error, :outside_workspace}`
2. `grep -f/etc/passwd needle.txt` → `{:error, :outside_workspace}`
3. `grep --file=../outside/patterns needle.txt` → `{:error, :outside_workspace}`
4. `cat --show-all=.env` → `{:error, :secret_file}`
5. `ls --color=auto` → `{:ok, %{approval_required?: true}}` (regression guard)
6. `grep -rn needle lib` → `{:ok, ...}` (regression guard)

## Section 2 — Position-independent mutating-option rejection

### Changes

`@dangerous_command_patterns` keeps its current contents (Spec C constraint). The `sed -i` gap is closed in the new argv-based stage instead, where reordering cannot defeat it:

```elixir
# Options that make an otherwise read-only program write. Matched against the
# whole argv vector, so `sed -E -i.bak` is caught as surely as `sed -i.bak`.
@mutating_options %{
  "sed" => [~r/^-{1,2}i/, ~r/^--in-place/]
}
```

A token matching any regex for the resolved program name yields `{:error, :dangerous_command}`.

`~r/^-{1,2}i/` covers `-i`, `-i.bak`, and `--in-place=.bak`. It also rejects `-idiotic`, which is not a real `sed` option — over-rejection is the correct failure direction here.

### Behaviour deltas

- `sed -E -i.bak s/a/b/ f.txt` → `{:error, :dangerous_command}` (was `{:ok, ...}`, and **wrote the file**).
- `sed -i.bak s/a/b/ f.txt` → `{:error, :dangerous_command}` (unchanged; the string deny-list already caught it, and now the argv stage does too).
- `sed -n 1,5p f.txt` → `{:ok, ...}`, unchanged.

### Tests

1. `sed -E -i.bak s/foo/bar/ README.md` → `{:error, :dangerous_command}`
2. `sed --in-place=.bak s/foo/bar/ README.md` → `{:error, :dangerous_command}`
3. `sed -i.bak s/foo/bar/ README.md` → `{:error, :dangerous_command}` (regression guard for the string deny-list)
4. `sed -n 1,5p README.md` → `{:ok, ...}` (regression guard)
5. An end-to-end case in `test/mr_eric/tools/shell_command_test.exs`: write a workspace file, run `sed -E -i.bak ...` through `ShellCommand.run/2`, assert `{:error, :dangerous_command}` **and** that the file content is unchanged. This is the case that actually proves the write is prevented; the `Policy` unit tests only prove the decision.

## Section 3 — Per-program option allow-list and bare program names

### Changes

**3-1. Reject options that re-point a program's root or name a program to run.**

```elixir
# Options that change what the program considers its own root, or that can
# name another program to execute. Rejected regardless of position.
@root_repointing_options %{
  "git" => [~r/^--git-dir(=|$)/, ~r/^--work-tree(=|$)/, ~r/^--exec-path(=|$)/, ~r/^-c$/, ~r/^--namespace(=|$)/]
}
```

`-C <path>` is deliberately **not** rejected: `git_subcommand/1` already skips it when locating the subcommand, and its argument is a separate token that `ensure_command_paths_allowed/2` resolves through `Policy`. Section 1 does not change that. Rejecting `-c` (config) while allowing `-C` (chdir) is the intended asymmetry; the test suite must pin it so the two are not conflated later.

**3-2. Require a bare program name.**

```elixir
defp ensure_allowed_shell_command(command) do
  with {:ok, [program | args]} <- command_argv(command) do
    cond do
      String.contains?(program, "/") -> {:error, :dangerous_command}
      program not in @allowed_shell_commands -> {:error, :dangerous_command}
      program == "git" and git_subcommand(args) not in @allowed_git_subcommands ->
        {:error, :dangerous_command}
      true -> :ok
    end
  end
end
```

`Path.basename/1` is dropped. With the `/` check in front of it, it can no longer differ from `program`, and keeping it would preserve the misleading impression that a path is acceptable. This makes the allow-listed string and the `System.find_executable/1` argument the same string — Goal 4.

### Behaviour deltas

- `git --git-dir=../store --work-tree=../outside status` → `{:error, :dangerous_command}` (was `{:ok, ...}` and **listed files outside the workspace**).
- `git -c core.fsmonitor=evil status` → `{:error, :dangerous_command}`.
- `git -C sub status` → `{:ok, ...}`, unchanged, with `sub` still resolved through `Policy`.
- `./pwd`, `tmp/pwd`, `bin/git` → `{:error, :dangerous_command}` (were `{:ok, ...}`; not exploitable, but the mismatch is closed).
- `/usr/bin/pwd` → `{:error, :outside_workspace}`, unchanged (caught earlier by absolute-path resolution).

### Tests

1. `git --git-dir=../gitstore --work-tree=../outside status --short` → `{:error, :dangerous_command}`
2. `git -c core.fsmonitor=evil status` → `{:error, :dangerous_command}`
3. `git -C sub status --short` → `{:ok, ...}` (regression guard; pins the `-c` / `-C` asymmetry)
4. `git status --short` → `{:ok, ...}` (regression guard)
5. `./pwd` and `tmp/pwd` → `{:error, :dangerous_command}`
6. `pwd` → `{:ok, ...}` (regression guard)
7. An end-to-end case in `shell_command_test.exs`: a real git repo outside the workspace, `git --git-dir=... --work-tree=... status --short` through `ShellCommand.run/2`, assert `{:error, :dangerous_command}` and that no outside content appears in any result.

## Risks and follow-ups

| Risk | Mitigation |
|------|------------|
| The option allow-list over-rejects a legitimate command the model wants to run | Correct failure direction. The model sees `:dangerous_command` and retries with a simpler form. Every rejection listed above has a permitted equivalent. |
| `option_value_paths/1` misreads a non-path option value as a path | Only values that survive `resolve_workspace_path/2` matter, and a non-path value like `auto` resolves inside the workspace and passes. Pinned by the `ls --color=auto` regression test. |
| A future program added to `@allowed_shell_commands` brings an unmodelled mutating option | `@mutating_options` / `@root_repointing_options` are keyed by program name and default to "no restrictions". Adding a program **must** come with an entry or a written argument for why none is needed. Stated in the plan's constraints. |
| Bare-program-name enforcement breaks a caller passing an absolute path | No such caller exists; absolute program paths were already rejected by `embedded_absolute_path/1`. Pinned by test. |
| `-c` vs `-C` is conflated by a later editor | Test 3 in Section 3 fails loudly if either changes. |

Follow-ups explicitly left elsewhere:

- Process sandboxing for the child — no spec owns this yet.
- `ApplyPatch.apply_validated/2` visibility — deliberately unchanged, see "What is *not* broken".
- `max_children` and trace/history caps — **Spec D**.

## Acceptance criteria

1. `sed -E -i.bak s/foo/bar/ README.md` through `ShellCommand.run/2` returns `{:error, :dangerous_command}` **and** leaves the target file byte-identical.
2. `grep -f<path outside the workspace> needle.txt` returns `{:error, :outside_workspace}`, for both absolute and `../`-relative forms, and for `-f` and `--file=`.
3. `git --git-dir=... --work-tree=... status --short` returns `{:error, :dangerous_command}` and no outside content reaches any result field.
4. `git -C sub status`, `ls --color=auto`, `grep -rn needle lib`, `sed -n 1,5p f.txt`, and `pwd` all still return `{:ok, %{approval_required?: true}}`.
5. A program token containing `/` returns `{:error, :dangerous_command}`; `Path.basename/1` no longer appears in `ensure_allowed_shell_command/1`.
6. `@allowed_shell_commands`, `@allowed_git_subcommands`, `@forbidden_shell_syntax`, and `@dangerous_command_patterns` are byte-identical to their Spec C state.
7. The `shell_command` schema, the approval-request map, and every tool result shape are unchanged. `priv/evals/phase9_golden_cases.json` is unmodified and `mix mr_eric.evals` passes.
8. `mix precommit` passes.

## Out of scope (tracked elsewhere)

- Spec D — Run lifetime and resources (`max_children`, trace/history caps)
- Spec E — eval/RAG correctness (scorer early-pass, RAG cache, `rag_default_index` golden case)
- Spec F — production HTTP (`force_ssl`, HSTS, CSP, `PHX_HOST` hard-fail)
- Ecto/DB persistence, login and multi-user auth, `git commit`/`push`/`reset`/`clean`, force push, automatic rollback — permanently out of scope for this project.
