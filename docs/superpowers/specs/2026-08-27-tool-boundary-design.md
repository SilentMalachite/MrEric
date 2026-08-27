# Spec C — Tool Boundary Hardening

- **Date:** 2026-08-27
- **Status:** Implemented on `main` (2026-08-27)
- **Plan:** `docs/superpowers/plans/2026-08-27-tool-boundary.md`
- **Scope:** Third of six security-hardening specs derived from the 2026-05-05 audit report.
- **Tracks audit findings:** shell interpretation of approved commands, case-sensitive `.git`/`.ssh` exclusion, check-to-use gap between `Policy.authorize/3` and tool execution (all medium-severity).
- **Threat model:** Local single-user dev tool. Protect against a compromised or confused model turning an approved, narrowly-scoped tool call into a wider capability than the user believed they approved. Multi-user authentication is out of scope.

## Background

Spec A closed the secret-hygiene holes and Spec B bound runs and approvals to a session owner. What remains is the execution surface *behind* the approval gate: what actually happens once the user clicks approve.

Three concrete gaps:

**1. Approved commands still run through a login shell.** `MrEric.Tools.ShellCommand.run/2` executes `System.cmd("sh", ["-lc", command], ...)` (`lib/mr_eric/tools/shell_command.ex:36`). `MrEric.Tools.Policy` validates the command as a *string* — it rejects shell metacharacters and checks an allow-list of program names — but the string is then handed to a shell that re-parses it under its own grammar. Two properties follow from that:

- The validator and the executor use different parsers. Any construct the Policy tokenizer sees differently from `sh` is a candidate bypass. Today the metacharacter deny-list is broad enough that no such divergence is known, but the architecture leaves the question open, and every future relaxation of the deny-list reopens it.
- `-l` makes it a *login* shell, so `/etc/profile`, `~/.profile`, `~/.zprofile` and friends are sourced before the command runs. Those files can prepend to `PATH`, define shell functions, and set aliases. Spec A carefully reduced the child environment to an allow-list; a login shell then re-populates part of it from the user's dotfiles, outside the allow-list's control.

**2. `.git` and `.ssh` are matched case-sensitively.** `Policy.secret_path?/1` (`lib/mr_eric/tools/policy.ex:256`) tests `Enum.any?(segments, &(&1 in [".git", ".ssh"]))`. The rest of the function is already case-insensitive: `.env*` is compared after `String.downcase/1`, and the `id_rsa` / `*.pem` / `secret|credential|token` rules all carry the `i` flag. The segment test is the one exception. On macOS, whose default filesystem is case-insensitive, `.GIT/config` and `.Ssh/id_ed25519` resolve to exactly the same files as their lowercase forms while sailing past the check. `secret_path?/1` is the single source of truth for both tool path resolution and `MrEric.RAG.Index` exclusion, so the hole is reachable from `file_read`, `file_write_proposal`, `apply_patch`, `git_diff`, the `shell_command` path-token check, and RAG indexing alike.

**3. Validation happens at the Executor, use happens in the tool.** `Executor.execute/3` calls `Policy.authorize/3` and then `module.run(args, opts)`. `FileRead` and `ApplyPatch` re-resolve their paths through `Policy` inside `run/2`, so they carry their own boundary. `ShellCommand.run/2` does not: it reads `Policy.arg(args, :command)` and executes it. Anything that reaches `ShellCommand.run/2` without passing through `Executor` — a test, an IEx session, a future refactor that adds a second call site — executes an unvalidated command string. That is a check-to-use gap in the structural sense, independent of any timing race.

`ApplyPatch` has the narrower, classical TOCTOU shape: `PatchValidator.validate/2` resolves each target path and walks every segment with `File.lstat/1` to reject symlinks, and then `apply_proposal/2` calls `File.write!/2` on the previously-resolved absolute path. Between those two moments a path segment can be replaced with a symlink pointing outside the workspace, and the write follows it.

This spec closes all three.

## Goals

- Execute approved shell commands as a direct argv vector, with no shell process between the validator and the program. The tokenization that `Policy` validates must be the exact tokenization that is executed.
- Make `.git` and `.ssh` segment matching case-insensitive, so a case-insensitive filesystem cannot be used to reach protected directories.
- Give `ShellCommand.run/2` its own policy boundary, so the tool is safe when called directly and not only when called through `Executor`.
- Re-resolve `apply_patch` targets through `Policy` immediately before each write, so a symlink swapped in after validation is caught.
- Keep the tool result shapes, the `shell_command` schema, and the approval-request payload unchanged, so LiveView, the orchestrator prompts, `tool_call_parser`, and the golden eval cases need no updates.

## Non-Goals

- Widening `@allowed_shell_commands`. The allow-list stays `pwd ls cat sed grep rg git`. Removing the shell is not a licence to allow more programs.
- Adding shell features back through another door — no pipe support, no redirection support, no glob expansion, no quoted arguments. `Policy`'s existing `@forbidden_shell_syntax` deny-list stays exactly as it is.
- Replacing the string `command` argument with an `argv` array in the tool schema. The string stays; `Policy` owns the split. (Considered and rejected: an array schema removes parsing ambiguity, but forces coordinated changes across the orchestrator prompts, `tool_call_parser`, the approval UI and the golden cases for no additional safety, given that the deny-list already guarantees whitespace-splitting is faithful.)
- Atomic open-then-verify primitives (`O_NOFOLLOW`, `openat` with a directory fd). Erlang's `:file` module does not expose them, and a NIF is disproportionate for a local single-user dev tool. Re-resolution immediately before use narrows the window to microseconds; it does not close it to zero, and this spec says so rather than pretending otherwise.
- Sandboxing the child process (seccomp, sandbox-exec, container). Tracked nowhere yet; out of scope for this spec.
- Changing the approval-token HMAC, the TTL, or anything else Spec B introduced.

## Architecture overview

Before — two parsers, one boundary:

```
Executor.execute/3
      |
      | Policy.authorize(:shell_command, %{command: "grep -rn foo lib"})
      |   -> tokenize: ["grep", "-rn", "foo", "lib"]
      |   -> deny-list check, allow-list check, path-token check
      v
ShellCommand.run/2
      |
      | System.cmd("sh", ["-lc", "grep -rn foo lib"])
      v
   /bin/sh -l   <-- sources profile files, re-parses the string
      |
      v
    grep
```

After — one parser, two boundaries:

```
Executor.execute/3
      |
      | Policy.authorize(:shell_command, args, opts)      (gate 1)
      v
ShellCommand.run/2
      |
      | Policy.authorize(:shell_command, args, opts)      (gate 2, same code path)
      | Policy.command_argv("grep -rn foo lib")
      |   -> {:ok, ["grep", "-rn", "foo", "lib"]}          (same tokenizer as gate 1 and 2)
      | System.find_executable("grep") -> "/usr/bin/grep"
      |
      | System.cmd("/usr/bin/grep", ["-rn", "foo", "lib"],
      |            cd: workspace, env: build_env(), stderr_to_stdout: true)
      v
    grep                                                   (no shell, no profile files)
```

The property the redesign buys: `command_argv/1` and the tokenizer inside `ensure_safe_command/1` are the same function. There is no second grammar for a command string to mean something different under.

## Section 1 — `Policy.command_argv/1` and argv-direct execution

### Changes

**`lib/mr_eric/tools/policy.ex`** — promote the existing private tokenizer to a public, documented entry point:

```elixir
@doc """
Splits an already-authorized command string into an argv vector.

Uses the same tokenizer as `authorize/3`, so the argv that is executed is by
construction the argv that was validated. Callers must still run `authorize/3`
first: this function performs no safety checks of its own.
"""
@spec command_argv(String.t()) :: {:ok, [String.t(), ...]} | {:error, :invalid_args}
def command_argv(command) when is_binary(command) do
  case command_tokens(command) do
    [] -> {:error, :invalid_args}
    tokens -> {:ok, tokens}
  end
end

def command_argv(_command), do: {:error, :invalid_args}
```

`command_tokens/1` and `clean_command_token/1` stay private and stay exactly as they are. Both existing internal callers — `ensure_allowed_shell_command/1` and `ensure_command_paths_allowed/2` — are refactored to route through `command_argv/1`, so after this change every tokenization in the system, validation and execution alike, is the same call.

**`lib/mr_eric/tools/shell_command.ex`** — replace the body of `run/2`:

```elixir
@impl true
def run(args, opts) do
  args = Policy.normalize_args(args)

  with {:ok, _decision} <- Policy.authorize(:shell_command, args, opts),
       {:ok, command} <- fetch_command(args),
       {:ok, [program | argv]} <- Policy.command_argv(command),
       {:ok, executable} <- resolve_executable(program) do
    {output, exit_status} =
      System.cmd(executable, argv,
        cd: Policy.workspace_root(opts),
        stderr_to_stdout: true,
        env: build_env()
      )

    {:ok, %{command: command, output: output, exit_status: exit_status}}
  end
rescue
  error -> {:error, Exception.message(error)}
end

defp resolve_executable(program) do
  case System.find_executable(program) do
    nil -> {:error, :dangerous_command}
    path -> {:ok, path}
  end
end
```

Notes on the details:

- `System.find_executable/1` resolves against the **BEAM's** `PATH`, not the child's allow-listed `PATH`. That is the desired direction: the program is chosen by the server's environment, and the absolute path is handed to `System.cmd/3`, so the command still runs correctly even if an operator removes `PATH` from `:shell_env_allowlist` entirely.
- `System.cmd/3` raises `ErlangError` when given a program it cannot execute. Resolving first turns that into a `{:error, :dangerous_command}` tuple, which is a value `RunWorker` and `MrEric.Errors` already know how to render.
- The `%{command: command, output: output, exit_status: exit_status}` result keeps `command` as the original string, so the approval UI, `Trace`, and the golden cases see exactly what they see today.
- `build_env/0`, `resolve_allowlist/0` and `maybe_warn/2` are untouched. Spec A's allow-list keeps working, and now it is the *whole* story for the child environment, because no login shell re-populates it afterwards.

### Behaviour deltas

Removing the shell changes observable behaviour in a few places. All of them are acceptable; recording them so they are not later mistaken for regressions:

- **`pwd` becomes `/bin/pwd`.** It was a shell builtin printing the *logical* working directory; the binary prints the *physical* one, resolving symlinks. On macOS a workspace under `System.tmp_dir!()` therefore reports `/private/var/folders/...` where it previously reported `/var/folders/...`. `test/mr_eric/tools/executor_test.exs:82` asserts on `Path.basename(workspace)` only, so it is unaffected — but a future assertion on the full path would be.
- **Profile-file side effects disappear.** A `PATH` prepended in `~/.zprofile` no longer influences which binary runs. This is the point of the change, not a side effect of it.
- **A program on the allow-list but absent from `PATH` now fails as `:dangerous_command`** instead of as a shell "command not found" with exit status 127. `rg` is the realistic case: it is on `@allowed_shell_commands` but is not installed everywhere.

### Tests

`test/mr_eric/tools/shell_command_test.exs` (new):

- `run/2` executes an allowed command in the workspace and returns `%{command:, output:, exit_status:}` with the original command string preserved.
- `run/2` called **directly** with `%{command: "rm -rf tmp"}` returns `{:error, :dangerous_command}` — the tool boundary holds without `Executor`.
- `run/2` called directly with `%{command: "pwd; rm -rf tmp"}` returns `{:error, :dangerous_command}` — proving the string never reaches a shell that would honour `;`.
- `run/2` called directly with a path outside the workspace (`cat ../outside.txt`) returns `{:error, :outside_workspace}`.
- `run/2` with a blank or non-binary command returns `{:error, :invalid_args}`.
- A file whose name contains a glob character is **not** expanded: with `a.txt` present, `cat` on a literal `*` argument fails rather than matching. (Belt and braces — `*` is already rejected by `@forbidden_shell_syntax`, so this asserts `{:error, :dangerous_command}`.)

`test/mr_eric/tools/policy_test.exs` (extend):

- `command_argv/1` returns the argv vector for a normal command.
- `command_argv/1` returns `{:error, :invalid_args}` for `""`, whitespace-only, and non-binary input.
- `command_argv/1` agrees with what `authorize/3` accepted, for each command in the allow-list.

`test/mr_eric/tools/shell_command_env_test.exs` (rewrite): the existing cases drive `ShellCommand.run/2` with `sh -c 'echo $VAR'`, which is exactly what this spec removes. They are re-pointed at `build_env/0` directly, which is where the allow-list logic actually lives:

- default allow-list marks `FAKE_LEAK_TOKEN` for removal (`{"FAKE_LEAK_TOKEN", nil}` present in the returned list)
- default allow-list passes `PATH` through with its real value
- a configured `:names` entry lets a custom var through
- a configured `:patterns` entry lets matching vars through
- empty configured `:names` / `:patterns` fall back to the defaults
- a sensitive-looking configured name logs one warning

An integration case then asserts the end-to-end property those unit tests imply: run an allowed command in a workspace and confirm the child could not have seen the stripped variable.

## Section 2 — Case-folded `.git` / `.ssh` segment matching

### Changes

**`lib/mr_eric/tools/policy.ex`** — in `secret_path?/1`:

```elixir
@protected_dir_segments ~w(.git .ssh)

def secret_path?(relative) do
  segments = Path.split(relative)
  basename = Path.basename(relative)

  Enum.any?(segments, &(String.downcase(&1) in @protected_dir_segments)) or
    String.starts_with?(String.downcase(basename), ".env") or
    Regex.match?(~r/^id_(rsa|dsa|ecdsa|ed25519)$/i, basename) or
    Regex.match?(~r/\.(pem|key|p12|pfx)$/i, basename) or
    Regex.match?(~r/(secret|credential|token)/i, relative)
end
```

One line of logic, `@protected_dir_segments` extracted so the list is named rather than inline. `String.downcase/1` without `:default` is ASCII-only, which is correct here: the targets are two fixed ASCII names, and full Unicode case folding would only add locale surprises (Turkish dotless i and friends) to a comparison that does not need them.

The moduledoc gains one sentence recording that directory-segment matching is case-insensitive because macOS filesystems are.

### Blast radius

`secret_path?/1` is the single source of truth, so this change lands everywhere at once:

| Caller | Effect |
|--------|--------|
| `Policy.resolve_workspace_path/2` → `ensure_not_secret/2` | `file_read`, `file_write_proposal`, `apply_patch`, `git_diff` all reject `.GIT/...` and `.SSH/...` |
| `Policy.validate_command_token_path/2` | `shell_command` rejects the same paths as arguments |
| `MrEric.RAG.Index` | mixed-case `.git` / `.ssh` trees are excluded from the lexical index |

No caller needs to change. That is the payoff for Spec A having consolidated the rule here.

### Tests

`test/mr_eric/tools/policy_test.exs` (extend the existing `secret_path?/1` describe block):

- `.GIT/config`, `.Git/config` and `.git/config` are all secret
- `.SSH/id_ed25519` and `.ssh/id_ed25519` are all secret
- a path merely *containing* the letters — `lib/legit/thing.ex`, `docs/gitignore-notes.md` — is **not** secret (guards against a sloppy `String.contains?` implementation)
- `resolve_workspace_path/2` returns `{:error, :secret_file}` for `.GIT/config`
- `authorize(:shell_command, %{command: "cat .GIT/config"})` returns `{:error, :secret_file}`

## Section 3 — Re-validation at the point of use

### 3-1. `shell_command`

Covered by Section 1: `run/2` opens with `Policy.authorize(:shell_command, args, opts)`. The cost is one extra tokenization plus, for commands carrying path-shaped tokens, one extra `File.lstat/1` walk per token. Both are negligible against spawning a process.

This makes `Executor.execute/3`'s authorize call the *outer* gate rather than the *only* gate. `Executor` keeps its call unchanged — it needs `decision.approval_required?` regardless, so nothing is duplicated for its own sake.

### 3-2. `apply_patch` pre-write re-resolution

**`lib/mr_eric/tools/apply_patch.ex`** — `apply_proposal/2` for `:changes` mode currently writes to `change.full_path` computed during validation. Re-resolve the workspace-relative path immediately before each write and use the freshly-resolved absolute path:

```elixir
defp apply_proposal(%{mode: :changes, changes: changes}, opts) do
  Enum.reduce_while(changes, :ok, fn change, :ok ->
    case Policy.resolve_workspace_path(change.path, opts) do
      {:ok, full_path} ->
        full_path |> Path.dirname() |> File.mkdir_p!()
        File.write!(full_path, change.after_content)
        {:cont, :ok}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end)
rescue
  error -> {:error, Exception.message(error)}
end
```

`change.path` is the workspace-relative path `PatchValidator` produced via `Policy.relative_path/2`, so re-resolution re-runs the full chain: workspace containment, the per-segment `File.lstat/1` symlink walk, and `secret_path?/1` — now case-folded by Section 2.

Two honest limitations, stated rather than papered over:

- The window shrinks from "the whole of `PatchValidator.validate/2`" to "between `resolve_workspace_path/2` and `File.write!/2`". It is not zero. Closing it fully needs `O_NOFOLLOW`, which Erlang does not expose (see Non-Goals).
- `mkdir_p!` on the parent still runs after resolution. A directory created between the two is a new-directory race, not a symlink-follow, and creating a directory inside the workspace is what the tool is for.

`:unified_diff` mode needs no change: `git apply` is handed a patch whose target paths `PatchValidator` already resolved, and `git apply` refuses to write through symlinks itself.

`apply_patch` therefore ends up validating three times — `Policy.authorize/3`, `ApplyPatch.run/2`, and per-write. That is deliberate, and consistent with the "validates twice" pattern already documented in `CLAUDE.md`; the doc gets updated to say three.

### 3-3. `file_read` — no change, and why

`FileRead.run/2` resolves through `Policy` itself, and `ensure_no_symlink_segments/2` walks *every* segment including the last, so a symlink at the final path is rejected before `File.stat/1` or `File.read/1`. The residual window between resolution and read is the same microsecond-scale one `apply_patch` retains, and unlike `apply_patch` a read has no persistent effect. Leaving it alone is the right call; recording the reasoning here means Spec D does not have to rediscover it.

### Tests

`test/mr_eric/tools/apply_patch_test.exs` (new or extended):

- Applying a `:changes` proposal to a normal path still writes the file and returns a `git diff`.
- If a path segment is replaced by a symlink pointing outside the workspace *after* `PatchValidator.validate/2` has run and *before* the write, the write is refused with `{:error, :outside_workspace}` and the outside target is unmodified. The race is made deterministic by validating explicitly, swapping the symlink in, and then calling the apply step — not by racing two processes.
- A multi-change proposal where the second change fails re-resolution halts and reports the error. (The first change's write is not rolled back — `apply_patch` has never been atomic, and `CLAUDE.md` states rollback is manual via `git diff`.)

`test/mr_eric/tools/executor_test.exs` (extend):

- `execute_approved/2` for a `shell_command` whose command was mutated after signing still fails on the HMAC (Spec B behaviour, re-asserted here because Section 1 rearranges `run/2` around it).

## Risks and follow-ups

| Risk | Mitigation |
|------|------------|
| `rg` is on the allow-list but not installed on every machine; it now fails as `:dangerous_command` rather than exit 127 | Documented in Behaviour deltas. The model retries with `grep`, which is on the same allow-list. |
| A user's workflow depended on a profile-sourced `PATH` entry | Out of scope by design — Spec A already declared the child environment allow-list-only. |
| Triple validation on `apply_patch` costs three `File.lstat/1` walks per change | Negligible next to `git apply` and disk I/O; correctness wins. |
| `String.downcase/1` is ASCII-only | Intentional. The protected names are ASCII; Unicode folding would add locale edge cases without adding safety. |

Follow-ups explicitly left to later specs:

- Process sandboxing for the child (no spec owns this yet).
- `max_children` and trace/history caps — **Spec D**.
- `rag_default_index` golden case — **Spec E**, inherited from Spec A.

## Acceptance criteria

1. `grep -rn 'sh", \["-lc"' lib/` returns nothing. No shell process is spawned by any tool.
2. `Policy.command_argv/1` is public, documented, spec'd, and is the only tokenizer used by both `authorize/3` and `ShellCommand.run/2`.
3. `ShellCommand.run/2` called directly — bypassing `Executor` — rejects dangerous commands, out-of-workspace paths, and secret paths.
4. A program that is allow-listed but missing from `PATH` yields `{:error, :dangerous_command}`, never an unhandled `ErlangError`.
5. `.GIT/config`, `.Git/config`, `.SSH/id_ed25519` are all rejected by `resolve_workspace_path/2` and excluded by `MrEric.RAG.Index`.
6. A symlink swapped into an `apply_patch` target path after validation causes the write to be refused, and the file outside the workspace is unchanged.
7. The `shell_command` schema, the approval-request map, and every tool result shape are byte-identical to before. `priv/evals/phase9_golden_cases.json` is unmodified and `mix mr_eric.evals` passes.
8. `mix precommit` passes with no warnings.

## Out of scope (tracked elsewhere)

- Spec D — Run lifetime and resources (`max_children`, trace/history caps)
- Spec E — eval/RAG correctness (scorer early-pass, RAG cache, `rag_default_index` golden case)
- Spec F — production HTTP (`force_ssl`, HSTS, CSP, `PHX_HOST` hard-fail)
- Ecto/DB persistence, login and multi-user auth, `git commit`/`push`/`reset`/`clean`, force push, automatic rollback — permanently out of scope for this project.
