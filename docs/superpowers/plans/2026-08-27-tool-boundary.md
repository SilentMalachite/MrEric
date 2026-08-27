# Spec C — Tool Boundary Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the shell from approved `shell_command` execution, make `.git`/`.ssh` path exclusion case-insensitive, and re-validate at the point of use so every tool carries its own policy boundary.

**Architecture:** `MrEric.Tools.Policy` gains a public `command_argv/1` that is the single tokenizer for both authorization and execution. `MrEric.Tools.ShellCommand.run/2` re-runs `Policy.authorize/3` itself, splits the command with `command_argv/1`, resolves the program with `System.find_executable/1`, and executes the argv vector directly with `System.cmd/3` — no `sh -lc`, no login-shell profile sourcing. `Policy.secret_path?/1` case-folds its protected-directory segment test. `MrEric.Tools.ApplyPatch` re-resolves each change path through `Policy` immediately before writing it.

**Tech Stack:** Elixir 1.17, Phoenix 1.8, ExUnit. No new dependencies. No changes to tool schemas, result shapes, or the approval-request map.

**Spec:** `docs/superpowers/specs/2026-08-27-tool-boundary-design.md`

## Global Constraints

- **Respond to the user in Japanese**, leading with the conclusion (`CLAUDE.md`).
- **At most 3 files per commit.** Every task below is sized to respect this. Do not batch tasks into one commit.
- **`mix precommit` is the gate.** It runs `compile --warning-as-errors` + `deps.unlock --unused` + `test` in `:test` env. Warnings are errors.
- **No new HTTP libraries.** `Req` only. (Not touched by this plan, but the rule stands.)
- **Do not widen `@allowed_shell_commands`.** It stays `~w(pwd ls cat sed grep rg git)`.
- **Do not touch `@forbidden_shell_syntax` or `@dangerous_command_patterns`.** Removing the shell is not a licence to relax the deny-lists.
- **Do not modify `priv/evals/phase9_golden_cases.json`.** It must pass unchanged; that is acceptance criterion 7.
- **Tool result shapes are frozen.** `shell_command` keeps returning `%{command:, output:, exit_status:}` with `command` as the original string.
- **No external network in tests.** Existing rule; nothing in this plan needs it.

---

## File Structure

| Path | Disposition | Responsibility |
|------|-------------|----------------|
| `lib/mr_eric/tools/policy.ex` | modify | Case-fold protected dir segments; publish `command_argv/1` as the single tokenizer |
| `lib/mr_eric/tools/shell_command.ex` | modify | Self-authorize, then execute argv directly with no shell |
| `lib/mr_eric/tools/apply_patch.ex` | modify | Re-resolve each change path immediately before writing; expose `apply_validated/2` as a test seam |
| `test/mr_eric/tools/policy_test.exs` | modify | Case-fold cases; `command_argv/1` cases |
| `test/mr_eric/tools/shell_command_test.exs` | create | `run/2` boundary behaviour when called directly, without `Executor` |
| `test/mr_eric/tools/shell_command_env_test.exs` | modify | Re-point from `sh -c 'echo $VAR'` onto `build_env/0` |
| `test/mr_eric/tools/apply_patch_test.exs` | create | Pre-write re-resolution / TOCTOU cases |
| `docs/superpowers/README.md` | modify | Mark Spec C implemented; point "次にやる作業" at Spec D |
| `CLAUDE.md` | modify | Record argv execution and three-stage patch validation |
| `CHANGELOG.md` | modify | Security entry for Spec C |

Module boundaries stay as they are. `Policy` owns *what is allowed*; each tool owns *doing the allowed thing*, and now also re-asks `Policy` before doing it. `Executor` stays the broker and keeps its own `authorize/3` call, which it needs for `decision.approval_required?` regardless.

---

## Task 1: Case-fold `.git` / `.ssh` segment matching

Implements Spec Section 2. Landing this first means Task 3's `shell_command` tests inherit the fixed behaviour rather than encoding the broken one.

**Files:**
- Modify: `lib/mr_eric/tools/policy.ex:250-260` (`secret_path?/1`)
- Test: `test/mr_eric/tools/policy_test.exs` (extend the existing `describe "secret_path?/1 (public)"` block, and add two cases above it)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Policy.secret_path?/1` is case-insensitive for the segments `.git` and `.ssh`. Signature unchanged: `secret_path?(Path.t()) :: boolean()`. Tasks 3 and 4 rely on this for their secret-path assertions.

- [ ] **Step 1: Write the failing tests**

Add these three tests inside the existing `describe "secret_path?/1 (public)"` block in `test/mr_eric/tools/policy_test.exs`, after the `"true for paths under .git/"` test:

```elixir
    test "true for .git regardless of segment case" do
      assert MrEric.Tools.Policy.secret_path?(".git/config")
      assert MrEric.Tools.Policy.secret_path?(".GIT/config")
      assert MrEric.Tools.Policy.secret_path?(".Git/config")
      assert MrEric.Tools.Policy.secret_path?("nested/.GIT/config")
    end

    test "true for .ssh regardless of segment case" do
      assert MrEric.Tools.Policy.secret_path?(".ssh/id_ed25519")
      assert MrEric.Tools.Policy.secret_path?(".SSH/known_hosts")
      assert MrEric.Tools.Policy.secret_path?(".Ssh/config")
    end

    test "false for paths that merely contain the letters" do
      refute MrEric.Tools.Policy.secret_path?("lib/legit/thing.ex")
      refute MrEric.Tools.Policy.secret_path?("docs/gitignore-notes.md")
      refute MrEric.Tools.Policy.secret_path?("lib/mr_eric/ssh_helper.ex")
    end
```

And add these two tests at the top level of the module, immediately after the existing `test "protects likely secret files"`:

```elixir
  test "case-folded secret dirs are rejected by path resolution", %{workspace: workspace} do
    assert {:error, :secret_file} =
             Policy.resolve_workspace_path(".GIT/config", workspace_root: workspace)

    assert {:error, :secret_file} =
             Policy.resolve_workspace_path(".SSH/id_ed25519", workspace_root: workspace)
  end

  test "case-folded secret dirs are rejected as shell command arguments", %{
    workspace: workspace
  } do
    assert {:error, :secret_file} =
             Policy.authorize(:shell_command, %{command: "cat .GIT/config"},
               workspace_root: workspace
             )
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/mr_eric/tools/policy_test.exs`

Expected: FAIL. The `.GIT` / `.SSH` assertions fail because `Enum.any?(segments, &(&1 in [".git", ".ssh"]))` is case-sensitive; `resolve_workspace_path(".GIT/config", ...)` currently returns `{:ok, ...}` and `authorize(:shell_command, %{command: "cat .GIT/config"}, ...)` currently returns `{:ok, %{approval_required?: true}}`. The `refute` test passes already — that is intentional, it guards the fix against an over-broad `String.contains?` implementation.

- [ ] **Step 3: Implement the fix**

In `lib/mr_eric/tools/policy.ex`, add a module attribute next to the other allow-lists near the top of the module (below `@allowed_git_subcommands`):

```elixir
  # Matched case-insensitively: macOS filesystems are case-insensitive by
  # default, so `.GIT/config` reaches the same bytes as `.git/config`.
  @protected_dir_segments ~w(.git .ssh)
```

Then change the first clause of `secret_path?/1`:

```elixir
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

`String.downcase/1` without a `:mode` is ASCII-only. That is deliberate: the two protected names are ASCII, and full Unicode folding would add locale edge cases (Turkish dotless i) to a comparison that does not need them.

Also extend the `@doc` on `secret_path?/1` with one sentence:

```elixir
  Directory-segment matching (`.git`, `.ssh`) is case-insensitive because macOS
  filesystems are case-insensitive by default.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/mr_eric/tools/policy_test.exs`

Expected: PASS, all cases.

- [ ] **Step 5: Verify the RAG side of the blast radius did not regress**

Run: `mix test test/mr_eric/rag test/mr_eric/rag_test.exs`

Expected: PASS. `MrEric.RAG.Index` calls `secret_path?/1`, so this confirms the widened rule does not exclude files the index legitimately wants.

- [ ] **Step 6: Commit**

```bash
git add lib/mr_eric/tools/policy.ex test/mr_eric/tools/policy_test.exs
git commit -m "fix(policy): case-fold .git/.ssh segment matching in secret_path?/1"
```

---

## Task 2: Publish `Policy.command_argv/1` as the single tokenizer

Implements the first half of Spec Section 1. No behaviour change — this is the refactor that makes Task 3 possible and provably faithful.

**Files:**
- Modify: `lib/mr_eric/tools/policy.ex` (add `command_argv/1`; re-point `ensure_allowed_shell_command/1` and `ensure_command_paths_allowed/2` at it)
- Test: `test/mr_eric/tools/policy_test.exs` (add a new `describe` block)

**Interfaces:**
- Consumes: nothing from Task 1 (independent, but Task 1 lands first to keep the test file's history clean).
- Produces: `Policy.command_argv(String.t()) :: {:ok, [String.t(), ...]} | {:error, :invalid_args}`. Task 3 calls this to build the argv vector it executes.

- [ ] **Step 1: Write the failing tests**

Add this `describe` block to `test/mr_eric/tools/policy_test.exs`, immediately before the existing `describe "secret_path?/1 (public)"` block:

```elixir
  describe "command_argv/1 (Spec C)" do
    test "splits a command into an argv vector" do
      assert {:ok, ["grep", "-rn", "needle", "lib"]} =
               Policy.command_argv("grep -rn needle lib")
    end

    test "collapses repeated and surrounding whitespace" do
      assert {:ok, ["ls", "-la"]} = Policy.command_argv("  ls   -la  ")
    end

    test "returns invalid_args for empty or non-binary input" do
      assert {:error, :invalid_args} = Policy.command_argv("")
      assert {:error, :invalid_args} = Policy.command_argv("   ")
      assert {:error, :invalid_args} = Policy.command_argv(nil)
      assert {:error, :invalid_args} = Policy.command_argv(:pwd)
    end

    test "the argv head is the program authorize/3 allow-listed", %{workspace: workspace} do
      for {command, program} <- [
            {"pwd", "pwd"},
            {"ls -la", "ls"},
            {"cat note.txt", "cat"},
            {"git status --short", "git"}
          ] do
        assert {:ok, %{approval_required?: true}} =
                 Policy.authorize(:shell_command, %{command: command},
                   workspace_root: workspace
                 )

        assert {:ok, [^program | _rest]} = Policy.command_argv(command)
      end
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/mr_eric/tools/policy_test.exs`

Expected: FAIL with `(UndefinedFunctionError) function MrEric.Tools.Policy.command_argv/1 is undefined or private`.

- [ ] **Step 3: Implement `command_argv/1` and re-point the internal callers**

In `lib/mr_eric/tools/policy.ex`, add the public function next to the other public helpers (put it directly above `defp authorize_tool("file_read", ...)`, after `arg/2`):

```elixir
  @doc """
  Splits an already-authorized command string into an argv vector.

  Uses the same tokenizer as `authorize/3`, so the argv that gets executed is by
  construction the argv that was validated. This performs no safety checks of
  its own — callers must run `authorize/3` first.
  """
  @spec command_argv(term()) :: {:ok, [String.t(), ...]} | {:error, :invalid_args}
  def command_argv(command) when is_binary(command) do
    case command_tokens(command) do
      [] -> {:error, :invalid_args}
      tokens -> {:ok, tokens}
    end
  end

  def command_argv(_command), do: {:error, :invalid_args}
```

Then rewrite the two internal callers so no code path tokenizes except through `command_argv/1`.

Replace `ensure_allowed_shell_command/1`:

```elixir
  defp ensure_allowed_shell_command(command) do
    with {:ok, [program | args]} <- command_argv(command) do
      program = Path.basename(program)

      cond do
        program not in @allowed_shell_commands ->
          {:error, :dangerous_command}

        program == "git" and git_subcommand(args) not in @allowed_git_subcommands ->
          {:error, :dangerous_command}

        true ->
          :ok
      end
    end
  end
```

Replace `ensure_command_paths_allowed/2`:

```elixir
  defp ensure_command_paths_allowed(command, opts) do
    with {:ok, tokens} <- command_argv(command) do
      Enum.reduce_while(tokens, :ok, fn token, :ok ->
        case validate_command_token_path(token, opts) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end
```

Leave `command_tokens/1` and `clean_command_token/1` private and byte-identical. Do not change `@allowed_shell_commands`, `@allowed_git_subcommands`, `git_subcommand/1`, or `validate_command_token_path/2`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/mr_eric/tools/policy_test.exs`

Expected: PASS, all cases including the pre-existing ones. The pre-existing cases are the real regression check here — `ensure_allowed_shell_command/1` previously matched `[]` explicitly and now inherits that from `command_argv/1`, so `"   "` must still yield `{:error, :invalid_args}` (it is caught earlier by `normalize_command/1`, but the behaviour must not shift).

- [ ] **Step 5: Run the tool suite**

Run: `mix test test/mr_eric/tools`

Expected: PASS. Nothing outside `Policy` changed, so this is confirming the refactor was behaviour-preserving.

- [ ] **Step 6: Commit**

```bash
git add lib/mr_eric/tools/policy.ex test/mr_eric/tools/policy_test.exs
git commit -m "refactor(policy): publish command_argv/1 as the single command tokenizer"
```

---

## Task 3: argv-direct execution and self-authorization in `ShellCommand`

Implements the second half of Spec Section 1 plus Spec Section 3-1. This is the task that deletes `sh -lc`.

**Files:**
- Modify: `lib/mr_eric/tools/shell_command.ex:29-42` (`run/2`) and the moduledoc
- Create: `test/mr_eric/tools/shell_command_test.exs`
- Modify: `test/mr_eric/tools/shell_command_env_test.exs` (rewrite the cases that depend on shell expansion)

**Interfaces:**
- Consumes: `Policy.command_argv/1` from Task 2; `Policy.secret_path?/1` case folding from Task 1.
- Produces: `ShellCommand.run/2` returns `{:ok, %{command: String.t(), output: String.t(), exit_status: integer()}}` or `{:error, atom() | String.t()}` — same shape as before, with the added guarantee that it is safe when called directly. `build_env/0` is unchanged and stays `@doc false`.

- [ ] **Step 1: Write the failing tests for the new tool boundary**

Create `test/mr_eric/tools/shell_command_test.exs`:

```elixir
defmodule MrEric.Tools.ShellCommandTest do
  use ExUnit.Case, async: true

  alias MrEric.Tools.ShellCommand

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "mr-eric-shell-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, workspace: workspace}
  end

  test "runs an allowed command inside the workspace", %{workspace: workspace} do
    File.write!(Path.join(workspace, "note.txt"), "hello\n")

    assert {:ok, result} =
             ShellCommand.run(%{command: "cat note.txt"}, workspace_root: workspace)

    assert result.command == "cat note.txt"
    assert result.output == "hello\n"
    assert result.exit_status == 0
  end

  test "rejects a dangerous command when called without the Executor", %{workspace: workspace} do
    assert {:error, :dangerous_command} =
             ShellCommand.run(%{command: "rm -rf tmp"}, workspace_root: workspace)
  end

  test "a shell separator never reaches a shell", %{workspace: workspace} do
    File.write!(Path.join(workspace, "keep.txt"), "keep\n")

    assert {:error, :dangerous_command} =
             ShellCommand.run(%{command: "pwd; rm -rf keep.txt"}, workspace_root: workspace)

    assert File.read!(Path.join(workspace, "keep.txt")) == "keep\n"
  end

  test "glob characters are not expanded", %{workspace: workspace} do
    File.write!(Path.join(workspace, "a.txt"), "a\n")

    assert {:error, :dangerous_command} =
             ShellCommand.run(%{command: "cat *.txt"}, workspace_root: workspace)
  end

  test "rejects paths outside the workspace", %{workspace: workspace} do
    assert {:error, :outside_workspace} =
             ShellCommand.run(%{command: "cat ../outside.txt"}, workspace_root: workspace)
  end

  test "rejects secret paths", %{workspace: workspace} do
    assert {:error, :secret_file} =
             ShellCommand.run(%{command: "cat .env"}, workspace_root: workspace)

    assert {:error, :secret_file} =
             ShellCommand.run(%{command: "cat .GIT/config"}, workspace_root: workspace)
  end

  test "rejects a blank or missing command", %{workspace: workspace} do
    assert {:error, :invalid_args} =
             ShellCommand.run(%{command: "   "}, workspace_root: workspace)

    assert {:error, :invalid_args} = ShellCommand.run(%{}, workspace_root: workspace)
  end

  test "a non-zero exit status is returned, not raised", %{workspace: workspace} do
    assert {:ok, result} =
             ShellCommand.run(%{command: "cat missing.txt"}, workspace_root: workspace)

    assert result.exit_status != 0
  end

  test "an allow-listed program missing from PATH errors instead of raising", %{
    workspace: workspace
  } do
    result = ShellCommand.run(%{command: "rg --version"}, workspace_root: workspace)

    case System.find_executable("rg") do
      nil -> assert {:error, :dangerous_command} = result
      _path -> assert {:ok, %{exit_status: 0}} = result
    end
  end

  test "string keys are accepted", %{workspace: workspace} do
    File.write!(Path.join(workspace, "note.txt"), "hi\n")

    assert {:ok, %{output: "hi\n"}} =
             ShellCommand.run(%{"command" => "cat note.txt"}, workspace_root: workspace)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/mr_eric/tools/shell_command_test.exs`

Expected: FAIL. `"rejects a dangerous command when called without the Executor"` currently *runs* `rm -rf tmp` through `sh -lc` and returns `{:ok, ...}`; `"a shell separator never reaches a shell"` currently deletes `keep.txt`; `"rejects a blank or missing command"` currently raises or returns `{:ok, ...}`. Confirm these fail for those reasons and not because of a typo. Note that this failing state genuinely executes `rm -rf tmp` inside a throwaway temp workspace — that is safe, and it is the point of the test.

- [ ] **Step 3: Rewrite `ShellCommand.run/2`**

In `lib/mr_eric/tools/shell_command.ex`, replace the `run/2` implementation:

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

  defp fetch_command(args) do
    case Policy.arg(args, :command) do
      command when is_binary(command) -> {:ok, String.trim(command)}
      _other -> {:error, :invalid_args}
    end
  end

  defp resolve_executable(program) do
    case System.find_executable(program) do
      nil -> {:error, :dangerous_command}
      path -> {:ok, path}
    end
  end
```

`fetch_command/1` trims so the `command` echoed back in the result matches the argv that ran. `Policy.authorize/3` has already rejected the blank case by the time it is reached, so its `{:error, :invalid_args}` clause is defence in depth, not the primary guard.

Replace the moduledoc:

```elixir
  @moduledoc """
  Runs an approved shell command from the workspace root.

  The command is executed as a direct argv vector — there is no shell process
  between `MrEric.Tools.Policy` and the program, so nothing re-parses the
  command string under a second grammar and no login-shell profile is sourced.
  `Policy.command_argv/1` produces the argv, and it is the same tokenizer
  `Policy.authorize/3` validated with.

  `run/2` re-runs `Policy.authorize/3` itself. The tool is therefore safe when
  called directly and not only when brokered through `MrEric.Tools.Executor`.

  The child process inherits only environment variables on the configured
  allow-list. Every other parent env var is explicitly unset (`System.cmd/3`
  honours nil values as removals). Defaults are intentionally minimal; expand
  via `config :mr_eric, :shell_env_allowlist, names: [...], patterns: [...]`.
  """
```

- [ ] **Step 4: Run the new tests to verify they pass**

Run: `mix test test/mr_eric/tools/shell_command_test.exs`

Expected: PASS, all cases.

- [ ] **Step 5: Rewrite the env test onto `build_env/0`**

The existing cases in `test/mr_eric/tools/shell_command_env_test.exs` drive `run/2` with `sh -c 'echo $VAR'`, which Step 3 correctly refuses (`sh` is not allow-listed, and `'`, `$` are forbidden syntax). Replace the whole file:

```elixir
defmodule MrEric.Tools.ShellCommandEnvTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MrEric.Tools.ShellCommand

  setup do
    System.put_env("FAKE_LEAK_TOKEN", "definitely-leaked")
    on_exit(fn -> System.delete_env("FAKE_LEAK_TOKEN") end)
    # Reset the once-per-boot warn guard so each test gets a clean slate.
    :persistent_term.erase({MrEric.Tools.ShellCommand, :warned})

    workspace =
      Path.join(System.tmp_dir!(), "mr-eric-shell-env-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, workspace: workspace}
  end

  # `build_env/0` returns a keyword-like list where a nil value means
  # "remove this var from the child", per System.cmd/3.
  defp env_value(env, name) do
    Enum.find_value(env, :missing, fn {key, value} -> if key == name, do: {:ok, value} end)
  end

  test "default allow-list marks arbitrary env vars for removal" do
    assert {:ok, nil} = env_value(ShellCommand.build_env(), "FAKE_LEAK_TOKEN")
  end

  test "default allow-list passes PATH through unchanged" do
    assert {:ok, value} = env_value(ShellCommand.build_env(), "PATH")
    assert value == System.get_env("PATH")
  end

  test "configured names allow-list lets a custom var through" do
    Application.put_env(:mr_eric, :shell_env_allowlist,
      names: ~w(PATH HOME USER LANG LC_ALL TERM TZ TMPDIR SHELL FAKE_LEAK_TOKEN)
    )

    on_exit(fn -> Application.delete_env(:mr_eric, :shell_env_allowlist) end)

    assert {:ok, "definitely-leaked"} = env_value(ShellCommand.build_env(), "FAKE_LEAK_TOKEN")
  end

  test "configured pattern allow-list lets matching vars through" do
    System.put_env("MR_ERIC_TEST_VAR", "ok-value")
    on_exit(fn -> System.delete_env("MR_ERIC_TEST_VAR") end)

    Application.put_env(:mr_eric, :shell_env_allowlist,
      names: ~w(PATH HOME USER LANG LC_ALL TERM TZ TMPDIR SHELL),
      patterns: [~r/^MR_ERIC_/]
    )

    on_exit(fn -> Application.delete_env(:mr_eric, :shell_env_allowlist) end)

    assert {:ok, "ok-value"} = env_value(ShellCommand.build_env(), "MR_ERIC_TEST_VAR")
  end

  test "empty configured names falls back to the defaults" do
    Application.put_env(:mr_eric, :shell_env_allowlist, names: [], patterns: [])
    on_exit(fn -> Application.delete_env(:mr_eric, :shell_env_allowlist) end)

    env = ShellCommand.build_env()

    assert {:ok, value} = env_value(env, "PATH")
    assert is_binary(value)
    assert {:ok, nil} = env_value(env, "FAKE_LEAK_TOKEN")
  end

  test "warns once when a configured name looks sensitive" do
    Application.put_env(:mr_eric, :shell_env_allowlist,
      names: ~w(PATH GITHUB_TOKEN),
      patterns: []
    )

    on_exit(fn -> Application.delete_env(:mr_eric, :shell_env_allowlist) end)
    on_exit(fn -> :persistent_term.erase({MrEric.Tools.ShellCommand, :warned}) end)

    log = capture_log(fn -> ShellCommand.build_env() end)

    assert log =~ "GITHUB_TOKEN"
    assert log =~ "likely-sensitive"

    refute capture_log(fn -> ShellCommand.build_env() end) =~ "likely-sensitive"
  end

  test "commands still execute with the stripped child environment", %{workspace: workspace} do
    File.write!(Path.join(workspace, "note.txt"), "hello\n")

    assert {:ok, %{exit_status: 0, output: "hello\n"}} =
             ShellCommand.run(%{command: "cat note.txt"}, workspace_root: workspace)
  end
end
```

Why the last case is shaped that way: with the shell gone there is no allow-listed program that prints its own environment, so the leak assertion moves to the `build_env/0` unit tests above. What the integration case is actually guarding is the regression that removing `PATH` from the child breaks execution — Step 3's `System.find_executable/1` resolution is what prevents it.

- [ ] **Step 6: Run the env tests to verify they pass**

Run: `mix test test/mr_eric/tools/shell_command_env_test.exs`

Expected: PASS, all cases.

- [ ] **Step 7: Verify `sh -lc` is gone and the wider suite still passes**

```bash
grep -rn 'sh", \["-lc"' lib/ || echo "no shell invocation: OK"
mix test
```

Expected: the grep prints `no shell invocation: OK`, and `mix test` passes.

Two places in `test/mr_eric/tools/executor_test.exs` deserve a specific look, because Step 3 rearranged the code they exercise:

- Line 82 asserts `String.ends_with?(String.trim(result.output), Path.basename(workspace))` for `pwd`. `/bin/pwd` prints the *physical* path (`/private/var/...` on macOS instead of `/var/...`), and the assertion holds because only the leading segments differ. If it fails, the fix is to the assertion, not to the implementation.
- The `describe "approval request shape (Spec B)"` block and `"execute_approved rejects forged shell approval requests"` assert that a `shell_command` approval whose payload was mutated after signing still fails the HMAC check. Spec C does not change that behaviour, but `run/2` was rewritten underneath it, so these are the re-assertion the spec's Section 3 test list calls for. No new test is needed — confirm these pass unchanged.

- [ ] **Step 8: Run the deterministic evals**

Run: `mix mr_eric.evals`

Expected: PASS with `priv/evals/phase9_golden_cases.json` unmodified. The golden cases issue `shell_command` with `command: "pwd"`, which now resolves to `/bin/pwd`.

- [ ] **Step 9: Commit**

```bash
git add lib/mr_eric/tools/shell_command.ex \
        test/mr_eric/tools/shell_command_test.exs \
        test/mr_eric/tools/shell_command_env_test.exs
git commit -m "feat(shell_command): execute argv directly and self-authorize, dropping sh -lc"
```

---

## Task 4: `apply_patch` pre-write re-resolution

Implements Spec Section 3-2.

**Files:**
- Modify: `lib/mr_eric/tools/apply_patch.ex:27-48` (`run/2` and the `:changes` clause of `apply_proposal/2`)
- Create: `test/mr_eric/tools/apply_patch_test.exs`

**Interfaces:**
- Consumes: `Policy.resolve_workspace_path/2` (existing); `Policy.secret_path?/1` case folding from Task 1.
- Produces: `ApplyPatch.apply_validated(proposal :: map(), opts :: keyword()) :: {:ok, map()} | {:error, term()}` — a `@doc false` seam that applies an already-validated proposal and returns the same result `run/2` returns. `run/2` becomes `validate |> apply_validated`. Nothing outside the test relies on the seam.

- [ ] **Step 1: Write the failing tests**

Create `test/mr_eric/tools/apply_patch_test.exs`:

```elixir
defmodule MrEric.Tools.ApplyPatchTest do
  use ExUnit.Case, async: true

  alias MrEric.Tools.ApplyPatch
  alias MrEric.Tools.PatchValidator

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "mr-eric-apply-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    outside =
      Path.join(System.tmp_dir!(), "mr-eric-outside-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    {:ok, workspace: workspace, outside: outside}
  end

  test "applies a changes proposal", %{workspace: workspace} do
    File.mkdir_p!(Path.join(workspace, "notes"))
    File.write!(Path.join(workspace, "notes/task.md"), "old\n")

    assert {:ok, result} =
             ApplyPatch.run(
               %{changes: [%{path: "notes/task.md", before: "old\n", after: "new\n"}]},
               workspace_root: workspace
             )

    assert result.applied? == true
    assert result.changed_files == ["notes/task.md"]
    assert File.read!(Path.join(workspace, "notes/task.md")) == "new\n"
  end

  test "refuses to write when a path segment becomes a symlink after validation", %{
    workspace: workspace,
    outside: outside
  } do
    File.write!(Path.join(outside, "task.md"), "outside\n")

    notes = Path.join(workspace, "notes")
    File.mkdir_p!(notes)
    File.write!(Path.join(notes, "task.md"), "old\n")

    args = %{changes: [%{path: "notes/task.md", before: "old\n", after: "new\n"}]}
    opts = [workspace_root: workspace]

    # Validation passes while `notes` is still a real directory.
    assert {:ok, proposal} = PatchValidator.validate(args, opts)

    # Swap the directory for a symlink pointing outside the workspace.
    File.rm_rf!(notes)
    File.ln_s!(outside, notes)

    assert {:error, :outside_workspace} = ApplyPatch.apply_validated(proposal, opts)
    assert File.read!(Path.join(outside, "task.md")) == "outside\n"
  end

  test "a multi-change proposal halts on the first re-resolution failure", %{
    workspace: workspace,
    outside: outside
  } do
    File.write!(Path.join(outside, "second.md"), "outside\n")

    File.write!(Path.join(workspace, "first.md"), "old-first\n")
    nested = Path.join(workspace, "nested")
    File.mkdir_p!(nested)
    File.write!(Path.join(nested, "second.md"), "old-second\n")

    args = %{
      changes: [
        %{path: "first.md", before: "old-first\n", after: "new-first\n"},
        %{path: "nested/second.md", before: "old-second\n", after: "new-second\n"}
      ]
    }

    opts = [workspace_root: workspace]

    assert {:ok, proposal} = PatchValidator.validate(args, opts)

    File.rm_rf!(nested)
    File.ln_s!(outside, nested)

    assert {:error, :outside_workspace} = ApplyPatch.apply_validated(proposal, opts)

    # apply_patch has never been atomic; rollback is manual via git diff.
    assert File.read!(Path.join(workspace, "first.md")) == "new-first\n"
    assert File.read!(Path.join(outside, "second.md")) == "outside\n"
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/mr_eric/tools/apply_patch_test.exs`

Expected: FAIL with `(UndefinedFunctionError) function MrEric.Tools.ApplyPatch.apply_validated/2 is undefined or private`. The first test ("applies a changes proposal") should pass already — it is the regression guard for Step 3.

- [ ] **Step 3: Add the seam and re-resolve before each write**

In `lib/mr_eric/tools/apply_patch.ex`, replace `run/2` and the `:changes` clause of `apply_proposal/2`:

```elixir
  @impl true
  def run(args, opts) do
    with {:ok, proposal} <- PatchValidator.validate(args, opts) do
      apply_validated(proposal, opts)
    end
  end

  @doc false
  # Applies an already-validated proposal. Split out of `run/2` so the
  # re-resolution guard can be exercised deterministically: a test validates,
  # swaps a symlink in, and then calls this.
  def apply_validated(proposal, opts) do
    with :ok <- apply_proposal(proposal, opts) do
      {:ok, PatchResult.success(proposal, git_diff(proposal.changed_files, opts))}
    end
  end

  defp apply_proposal(%{mode: :changes, changes: changes}, opts) do
    Enum.reduce_while(changes, :ok, fn change, :ok ->
      # Re-resolve immediately before writing: `PatchValidator` checked this
      # path earlier, and a segment can have become a symlink since.
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

Leave the `:unified_diff` clause of `apply_proposal/2`, `git_diff/2`, and `with_patch_file/2` untouched. `change.path` is the workspace-relative path `PatchValidator` produced via `Policy.relative_path/2`, so re-resolution re-runs workspace containment, the per-segment `File.lstat/1` symlink walk, and `secret_path?/1`.

Note the residual window: `File.write!/2` still follows whatever the path means at open time. Erlang exposes no `O_NOFOLLOW`, so this narrows the race to microseconds rather than closing it — the spec's Non-Goals say so explicitly, and this comment should not claim otherwise.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/mr_eric/tools/apply_patch_test.exs`

Expected: PASS, all three cases.

- [ ] **Step 5: Run the tool suite and the evals**

```bash
mix test test/mr_eric/tools
mix mr_eric.evals
```

Expected: PASS. `test/mr_eric/tools/executor_test.exs` has eight `apply_patch` cases that exercise `run/2` through `Executor`; they confirm the seam extraction did not change the public path.

- [ ] **Step 6: Commit**

```bash
git add lib/mr_eric/tools/apply_patch.ex test/mr_eric/tools/apply_patch_test.exs
git commit -m "fix(apply_patch): re-resolve change paths immediately before writing"
```

---

## Task 5: Documentation sync

**Files:**
- Modify: `docs/superpowers/README.md`
- Modify: `CLAUDE.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: Tasks 1–4 complete and committed.
- Produces: nothing consumed by code.

- [ ] **Step 1: Update the spec status table**

In `docs/superpowers/README.md`, change the Spec C row to:

```markdown
| C | tool 境界（`sh -lc` 廃止、`.git`/`.ssh` の case-fold、TOCTOU 再検証） | **Implemented**（2026-08-27, `main`） | [spec](./specs/2026-08-27-tool-boundary-design.md) · [plan](./plans/2026-08-27-tool-boundary.md) |
```

And replace the "次にやる作業" section with:

```markdown
## 次にやる作業

**Spec D** が次です。`RunSupervisor` に `max_children` が無く、`MrEric.Runs.Trace` と完了 run 履歴にも上限がありません。長時間動かしたときの資源上限が、承認ゲートの後ろに残っている最後の運用面の穴です。

Spec A から先送りされた `rag_default_index` golden case は Spec E の所有です。
```

- [ ] **Step 2: Update the architecture notes**

In `CLAUDE.md`, under "Tools, approval signing, and patch flow", change the patch-validation sentence from "runs twice" to three stages:

```markdown
- **Real filesystem writes happen only via `:apply_patch`, only after approval.** Patch
  validation (`MrEric.Tools.PatchValidator`) runs three times — at `Policy.authorize/3`,
  again in `ApplyPatch.run/2` before applying, and a final `Policy.resolve_workspace_path/2`
  re-resolution immediately before each write — rejecting workspace escapes, protected secret
  paths, symlink escapes (including ones swapped in after validation), binary/oversized/stale/
  deletion patches, and disallowed new-file extensions.
```

And under "Safety boundaries", replace the `:shell_command` bullet:

```markdown
- `:shell_command` is restricted to a read-oriented allowlist + read-only git subcommands,
  rejects shell expansion/redirection/mutating commands, and passes only an **env-var
  allowlist** to children (config key `:shell_env_allowlist`) so secrets don't leak.
  Approved commands are executed as a **direct argv vector** (`Policy.command_argv/1` →
  `System.cmd/3`) — there is no shell process, so nothing re-parses the validated string and
  no login-shell profile is sourced. `ShellCommand.run/2` re-runs `Policy.authorize/3` itself,
  so the boundary holds even when the tool is called without `Executor`.
```

- [ ] **Step 3: Add the changelog entry**

In `CHANGELOG.md`, under `## [Unreleased]` → `### Security`, add:

```markdown
- tool 境界を hardening（Spec C、2026-08-27）。
  - 承認済み `shell_command` を `sh -lc` 経由から **argv 直実行**に変更。`Policy.command_argv/1` を
    検証と実行で共有する唯一の tokenizer とし、文字列が別の文法で再解釈される経路を排除。
    login shell が dotfile から子プロセス環境を再汚染する問題も同時に解消。
  - `Policy.secret_path?/1` の `.git` / `.ssh` セグメント照合を case-insensitive に変更。
    case-insensitive filesystem（macOS 既定）で `.GIT/config` が読めていた穴を塞いだ。
  - `ShellCommand.run/2` が自身で `Policy.authorize/3` を再実行。`Executor` を経由しない
    呼び出しでも tool 境界が効く。
  - `ApplyPatch` が書き込み直前に各 change の path を `Policy.resolve_workspace_path/2` で
    再解決。検証後に差し替えられた symlink を検知する。
```

Also update the Unreleased preamble line so it reads `Spec A–C まで `main` に入っています。残りは Spec D–F です。`

- [ ] **Step 4: Run the full gate**

Run: `mix precommit`

Expected: PASS with zero warnings.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/README.md CLAUDE.md CHANGELOG.md
git commit -m "docs: mark Spec C implemented and record the tool boundary changes"
```

---

## Verification checklist

Run all of these before declaring Spec C done. Each maps to an acceptance criterion in the spec.

| # | Command | Expected |
|---|---------|----------|
| 1 | `grep -rn 'sh", \["-lc"' lib/` | no output |
| 2 | `grep -n "def command_argv" lib/mr_eric/tools/policy.ex` | one public definition, with `@spec` and `@doc` |
| 3 | `mix test test/mr_eric/tools/shell_command_test.exs` | PASS — direct calls are bounded |
| 4 | `mix test test/mr_eric/tools/shell_command_test.exs:"an allow-listed program missing from PATH errors instead of raising"` | PASS on machines with and without `rg` installed |
| 5 | `mix test test/mr_eric/tools/policy_test.exs` | PASS — `.GIT` / `.SSH` rejected |
| 6 | `mix test test/mr_eric/tools/apply_patch_test.exs` | PASS — post-validation symlink swap refused |
| 7 | `git status --short priv/evals/` then `mix mr_eric.evals` | no modified golden cases; evals PASS |
| 8 | `mix precommit` | PASS, zero warnings |
