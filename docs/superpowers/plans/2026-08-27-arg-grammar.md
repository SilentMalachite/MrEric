# Spec C-1 — Command Argument Grammar Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close three verified `shell_command` bypasses that survive Spec C: option-attached paths (`-fPATH`, `--opt=PATH`) escaping the workspace check, `sed -i` evading its deny-list rule by option reordering, and `git --git-dir`/`--work-tree`/`-c` re-pointing what the repository is.

**Architecture:** `MrEric.Tools.Policy` gains one new private stage between `ensure_safe_command/1` and `ensure_command_paths_allowed/2` that reasons over the **argv vector** (`command_argv/1`) rather than the command string, so its checks are position-independent. `validate_command_token_path/2` learns to extract the value out of an option token before resolving it. `ensure_allowed_shell_command/1` requires a bare program name. `@forbidden_shell_syntax` and `@dangerous_command_patterns` keep their exact Spec C contents.

**Tech Stack:** Elixir 1.17, Phoenix 1.8, ExUnit. No new dependencies. No changes to tool schemas, result shapes, or the approval-request map.

**Spec:** `docs/superpowers/specs/2026-08-27-arg-grammar-design.md`

**Depends on:** Spec C in `main` (`Policy.command_argv/1`, argv-direct execution in `ShellCommand.run/2`).

## Global Constraints

- **Respond to the user in Japanese**, leading with the conclusion (`CLAUDE.md`).
- **At most 3 files per commit.** Every task below is sized to respect this. Do not batch tasks into one commit.
- **`mix precommit` is the gate.** It runs `compile --warning-as-errors` + `deps.unlock --unused` + `test` in `:test` env.
- **Do not widen `@allowed_shell_commands`.** It stays `~w(pwd ls cat sed grep rg git)`.
- **Do not modify `@forbidden_shell_syntax` or `@dangerous_command_patterns`.** New coverage goes in the argv stage, not the string deny-lists. Acceptance criterion 6 checks this with `git diff`.
- **Do not modify `priv/evals/phase9_golden_cases.json`.** Acceptance criterion 7.
- **Every regression-guard test in this plan is load-bearing.** The failure mode of this spec is over-rejection; the guards are what detect it. Do not delete one to make a task pass.
- **Adding a program to `@allowed_shell_commands` later requires a `@mutating_options` / `@root_repointing_options` entry** or a written argument for why none is needed. Record that in the moduledoc.

---

## File Structure

| Path | Disposition | Responsibility |
|------|-------------|----------------|
| `lib/mr_eric/tools/policy.ex` | modify | Option-value extraction; argv-based per-program option allow-list; bare program name |
| `test/mr_eric/tools/policy_test.exs` | modify | Decision-level cases for all three sections plus regression guards |
| `test/mr_eric/tools/shell_command_test.exs` | modify | End-to-end cases proving the *effect* is prevented, not just the decision |
| `docs/superpowers/README.md` | modify | Mark Spec C-1 implemented; point "次にやる作業" at Spec D |
| `CLAUDE.md` | modify | Record the argument-grammar boundary |
| `CHANGELOG.md` | modify | Security entry for Spec C-1 |

`Policy` still owns *what is allowed*; the tools still own *doing the allowed thing*. This plan only deepens what `Policy` inspects.

---

## Task 1: Reproduce the three bypasses as failing end-to-end tests

Do this first, in one commit, before any implementation. These tests assert on **effects** (file contents, leaked output), not just return values, and they are the only artifacts that prove the fix works rather than that the decision changed.

**Files:**
- Modify: `test/mr_eric/tools/shell_command_test.exs` (append three cases)

**Interfaces:**
- Consumes: `ShellCommand.run/2` as shipped by Spec C.
- Produces: three red tests that Tasks 2–4 turn green, one per section.

- [ ] **Step 1: Add the three end-to-end cases**

Append to `test/mr_eric/tools/shell_command_test.exs`, inside the existing module:

```elixir
  describe "argument grammar boundary (Spec C-1)" do
    test "sed cannot write in place, whatever the option order", %{workspace: workspace} do
      target = Path.join(workspace, "README.md")
      File.write!(target, "foo\n")

      assert {:error, :dangerous_command} =
               ShellCommand.run(%{command: "sed -E -i.bak s/foo/bar/ README.md"},
                 workspace_root: workspace
               )

      assert File.read!(target) == "foo\n"
      refute File.exists?(Path.join(workspace, "README.md.bak"))
    end

    test "grep cannot read a file outside the workspace via an attached -f", %{
      workspace: workspace
    } do
      outside =
        Path.join(System.tmp_dir!(), "mr-eric-outside-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)
      File.write!(Path.join(outside, "patterns"), "SECRET\n")
      File.write!(Path.join(workspace, "needle.txt"), "SECRET-value-here\n")

      assert {:error, :outside_workspace} =
               ShellCommand.run(
                 %{command: "grep -f#{Path.join(outside, "patterns")} needle.txt"},
                 workspace_root: workspace
               )
    end

    test "git cannot be re-pointed at a repository outside the workspace", %{
      workspace: workspace
    } do
      outside =
        Path.join(System.tmp_dir!(), "mr-eric-outside-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)
      File.write!(Path.join(outside, "SECRET.txt"), "top-secret\n")
      System.cmd("git", ["init", "-q"], cd: outside, stderr_to_stdout: true)

      assert {:error, :dangerous_command} =
               ShellCommand.run(
                 %{
                   command:
                     "git --git-dir=#{Path.join(outside, ".git")} " <>
                       "--work-tree=#{outside} status --short"
                 },
                 workspace_root: workspace
               )
    end
  end
```

Note the third case uses absolute paths for readability. `--git-dir=<absolute>` is *already* rejected today by `embedded_absolute_path/1` — but as `{:error, :outside_workspace}`, i.e. for a path reason rather than an option reason. Asserting `:dangerous_command` is therefore correct as an end-state assertion and this case goes green in Task 4, when `ensure_program_options_allowed/1` starts running ahead of the path check. Add the `../`-relative variant too, since that one is not blocked at all today:

```elixir
    test "git cannot be re-pointed via a relative --git-dir", %{workspace: workspace} do
      # `workspace` and `store` are siblings so `../store` is expressible.
      store = Path.join(Path.dirname(workspace), "store-#{System.unique_integer([:positive])}")
      File.mkdir_p!(store)
      on_exit(fn -> File.rm_rf!(store) end)
      System.cmd("git", ["init", "-q", "--bare", store], stderr_to_stdout: true)

      rel = Path.join("..", Path.basename(store))

      assert {:error, :dangerous_command} =
               ShellCommand.run(%{command: "git --git-dir=#{rel} status --short"},
                 workspace_root: workspace
               )
    end
```

- [ ] **Step 2: Run the tests to verify they fail — for the right reasons**

Run: `mix test test/mr_eric/tools/shell_command_test.exs`

Expected: the `sed`, `grep`, and relative-`--git-dir` cases FAIL. Read each failure and confirm the `right:` side is `{:ok, ...}` — that is the bypass firing. In particular:

- the `sed` case must fail on the `{:error, :dangerous_command}` match, and if you let it run past that, `File.read!(target)` would be `"bar\n"`;
- the `grep -f` and relative-`--git-dir` cases must fail with `right: {:ok, ...}` — that is the bypass firing;
- the absolute-`--git-dir` case fails with `right: {:error, :outside_workspace}`. That is **not** a bypass: the path check already blocks it. It goes green in Task 4 when the option check starts running first, and until then it pins the current reason.

Measured on `main` at `38a309e`: `sed` → `{:ok, exit_status: 0}` **and the file is rewritten**; `grep -f<abs>` → `{:ok, exit_status: 0}` with outside content matched; relative `--git-dir` → `{:ok, exit_status: 128}` (git found the repo, then refused for want of a work tree — the boundary was already crossed).

If a case fails for a reason not listed above, stop — the reproduction is wrong and the rest of the plan is built on it.

- [ ] **Step 3: Commit the red tests**

```bash
git add test/mr_eric/tools/shell_command_test.exs
git commit -m "test(shell_command): reproduce the Spec C-1 argument-grammar bypasses"
```

Committing red tests is deliberate here: it makes the bypasses reproducible from history independent of the fix.

---

## Task 2: Extract and validate option-attached paths

Implements Spec Section 1.

**Files:**
- Modify: `lib/mr_eric/tools/policy.ex` (`validate_command_token_path/2`, new `option_value_paths/1`, fold in `embedded_absolute_path/1`)
- Test: `test/mr_eric/tools/policy_test.exs` (new `describe` block)

**Interfaces:**
- Consumes: `Policy.command_argv/1` (Spec C).
- Produces: `validate_command_token_path/2` resolves paths carried inside `-XVALUE` and `--opt=VALUE`. Private; no public signature changes.

- [ ] **Step 1: Write the failing tests**

Add to `test/mr_eric/tools/policy_test.exs`, immediately before `describe "command_argv/1 (Spec C)"`:

```elixir
  describe "option-attached paths (Spec C-1)" do
    test "rejects a relative attached short-option path", %{workspace: workspace} do
      assert {:error, :outside_workspace} =
               Policy.authorize(:shell_command, %{command: "grep -f../outside/p needle.txt"},
                 workspace_root: workspace
               )
    end

    test "rejects an absolute attached short-option path", %{workspace: workspace} do
      assert {:error, :outside_workspace} =
               Policy.authorize(:shell_command, %{command: "grep -f/etc/passwd needle.txt"},
                 workspace_root: workspace
               )
    end

    test "rejects a long-option attached path", %{workspace: workspace} do
      assert {:error, :outside_workspace} =
               Policy.authorize(
                 :shell_command,
                 %{command: "grep --file=../outside/p needle.txt"},
                 workspace_root: workspace
               )
    end

    test "rejects a secret path carried in an option value", %{workspace: workspace} do
      assert {:error, :secret_file} =
               Policy.authorize(:shell_command, %{command: "grep --file=.env needle.txt"},
                 workspace_root: workspace
               )
    end

    test "still allows a non-path option value", %{workspace: workspace} do
      assert {:ok, %{approval_required?: true}} =
               Policy.authorize(:shell_command, %{command: "ls --color=auto"},
                 workspace_root: workspace
               )
    end

    test "still allows ordinary separated arguments", %{workspace: workspace} do
      assert {:ok, %{approval_required?: true}} =
               Policy.authorize(:shell_command, %{command: "grep -rn needle lib"},
                 workspace_root: workspace
               )
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/mr_eric/tools/policy_test.exs`

Expected: the first four FAIL with `right: {:ok, %{approval_required?: true}}`. The last two PASS already — they are the over-rejection guards for Step 3.

- [ ] **Step 3: Implement extraction**

In `lib/mr_eric/tools/policy.ex`, rename the current body of `validate_command_token_path/2` to `validate_plain_token_path/2` (unchanged contents), and add:

```elixir
  defp validate_command_token_path(token, opts) do
    case option_value_paths(token) do
      [] ->
        validate_plain_token_path(token, opts)

      values ->
        Enum.reduce_while(values, :ok, fn value, :ok ->
          case validate_plain_token_path(value, opts) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  # A path can hide inside an option token: `-fPATTERNS`, `--file=PATTERNS`.
  # The token as a whole expands to a harmless in-workspace string, so it must
  # be taken apart before `validate_plain_token_path/2` sees it.
  defp option_value_paths("--" <> rest) do
    case String.split(rest, "=", parts: 2) do
      [_name, value] when value != "" -> [value]
      _no_value -> []
    end
  end

  defp option_value_paths(<<?-, letter, value::binary>>) when value != "" do
    if letter in ?a..?z or letter in ?A..?Z, do: [value], else: []
  end

  defp option_value_paths(_token), do: []
```

Leave `embedded_absolute_path/1` in place — it still covers bare tokens such as `FOO=/etc/passwd` that carry no option prefix.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/mr_eric/tools/policy_test.exs`

Expected: PASS, all cases — including the two over-rejection guards.

- [ ] **Step 5: Confirm one of the end-to-end cases went green**

Run: `mix test test/mr_eric/tools/shell_command_test.exs`

Expected: the `grep -f` case now PASSES. The `sed` and relative-`--git-dir` cases still FAIL — Tasks 3 and 4 own those.

- [ ] **Step 6: Commit**

```bash
git add lib/mr_eric/tools/policy.ex test/mr_eric/tools/policy_test.exs
git commit -m "fix(policy): resolve paths carried inside option tokens"
```

---

## Task 3: Position-independent mutating-option rejection

Implements Spec Section 2.

**Files:**
- Modify: `lib/mr_eric/tools/policy.ex` (new `@mutating_options`, new `ensure_program_options_allowed/1`, wire into `authorize_tool("shell_command", ...)`)
- Test: `test/mr_eric/tools/policy_test.exs` (new `describe` block)

**Interfaces:**
- Consumes: `Policy.command_argv/1`.
- Produces: a new private stage in the `shell_command` authorization pipeline. Task 4 extends the same stage with `@root_repointing_options`.

- [ ] **Step 1: Write the failing tests**

```elixir
  describe "mutating options (Spec C-1)" do
    test "rejects sed -i however it is spelled or ordered", %{workspace: workspace} do
      for command <- [
            "sed -E -i.bak s/foo/bar/ README.md",
            "sed --in-place=.bak s/foo/bar/ README.md",
            "sed -i.bak s/foo/bar/ README.md",
            "sed -n -i s/foo/bar/ README.md"
          ] do
        assert {:error, :dangerous_command} =
                 Policy.authorize(:shell_command, %{command: command},
                   workspace_root: workspace
                 )
      end
    end

    test "still allows read-only sed", %{workspace: workspace} do
      assert {:ok, %{approval_required?: true}} =
               Policy.authorize(:shell_command, %{command: "sed -n 1,5p README.md"},
                 workspace_root: workspace
               )
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/mr_eric/tools/policy_test.exs`

Expected: the first test FAILS. Measured on `main` at `38a309e`, three of its four forms are allowed today and only one is blocked:

| Command | Today |
|---------|-------|
| `sed -E -i.bak s/foo/bar/ README.md` | **ALLOWED** |
| `sed --in-place=.bak s/foo/bar/ README.md` | **ALLOWED** |
| `sed -n -i s/foo/bar/ README.md` | **ALLOWED** |
| `sed -i.bak s/foo/bar/ README.md` | `{:error, :dangerous_command}` |

Only the last one is adjacent enough for `~r/(^|\s)sed\s+-i/` to fire — that is the positional weakness this task removes. The read-only guard (`sed -n 1,5p`) PASSES.

- [ ] **Step 3: Implement the argv stage**

Add near the other allow-lists:

```elixir
  # Options that make an otherwise read-only program write. Matched against the
  # argv vector, so option order cannot defeat them the way it defeats the
  # positional patterns in @dangerous_command_patterns.
  #
  # Adding a program to @allowed_shell_commands requires an entry here, or a
  # written argument in the spec for why the program has no mutating options.
  @mutating_options %{
    "sed" => [~r/^-{1,2}i/, ~r/^--in-place/]
  }
```

Add the stage:

```elixir
  defp ensure_program_options_allowed(command) do
    with {:ok, [program | args]} <- command_argv(command) do
      denied = Map.get(@mutating_options, program, [])

      if Enum.any?(args, fn arg -> Enum.any?(denied, &Regex.match?(&1, arg)) end) do
        {:error, :dangerous_command}
      else
        :ok
      end
    end
  end
```

Wire it into the pipeline, after `ensure_safe_command/1`:

```elixir
  defp authorize_tool("shell_command", args, opts) do
    command = arg(args, :command)

    with {:ok, command} <- normalize_command(command),
         :ok <- ensure_safe_command(command),
         :ok <- ensure_program_options_allowed(command),
         :ok <- ensure_command_paths_allowed(command, opts) do
      {:ok,
       %{
         approval_required?: true,
         reason: "Shell commands require explicit user approval."
       }}
    end
  end
```

`ensure_program_options_allowed/1` runs before the path check so a mutating option is reported as `:dangerous_command` rather than as whatever its argument happens to resolve to.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/mr_eric/tools/policy_test.exs`

Expected: PASS, all cases.

- [ ] **Step 5: Confirm the end-to-end effect is prevented**

Run: `mix test test/mr_eric/tools/shell_command_test.exs`

Expected: the `sed` case PASSES, **including its `File.read!(target) == "foo\n"` assertion**. That assertion is the point of the task; a green return value with a modified file would mean the stage runs too late.

- [ ] **Step 6: Commit**

```bash
git add lib/mr_eric/tools/policy.ex test/mr_eric/tools/policy_test.exs
git commit -m "fix(policy): reject mutating options regardless of argv position"
```

---

## Task 4: Per-program root-repointing options and bare program names

Implements Spec Section 3.

**Files:**
- Modify: `lib/mr_eric/tools/policy.ex` (`@root_repointing_options`, extend `ensure_program_options_allowed/1`, tighten `ensure_allowed_shell_command/1`)
- Test: `test/mr_eric/tools/policy_test.exs` (new `describe` block)

**Interfaces:**
- Consumes: `ensure_program_options_allowed/1` from Task 3.
- Produces: `git` can no longer be re-pointed; the program token must be a bare name.

- [ ] **Step 1: Write the failing tests**

```elixir
  describe "root-repointing options and bare program names (Spec C-1)" do
    test "rejects git options that re-point the repository", %{workspace: workspace} do
      for command <- [
            "git --git-dir=../store status --short",
            "git --work-tree=../outside status --short",
            "git -c core.fsmonitor=evil status",
            "git --exec-path=../bin status"
          ] do
        assert {:error, :dangerous_command} =
                 Policy.authorize(:shell_command, %{command: command},
                   workspace_root: workspace
                 )
      end
    end

    test "still allows git -C, which Policy resolves as a separate token", %{
      workspace: workspace
    } do
      File.mkdir_p!(Path.join(workspace, "sub"))

      assert {:ok, %{approval_required?: true}} =
               Policy.authorize(:shell_command, %{command: "git -C sub status --short"},
                 workspace_root: workspace
               )
    end

    test "still allows a plain git subcommand", %{workspace: workspace} do
      assert {:ok, %{approval_required?: true}} =
               Policy.authorize(:shell_command, %{command: "git status --short"},
                 workspace_root: workspace
               )
    end

    test "rejects a program token that is a path", %{workspace: workspace} do
      for command <- ["./pwd", "tmp/pwd", "bin/git status"] do
        assert {:error, :dangerous_command} =
                 Policy.authorize(:shell_command, %{command: command},
                   workspace_root: workspace
                 )
      end
    end

    test "still allows a bare program name", %{workspace: workspace} do
      assert {:ok, %{approval_required?: true}} =
               Policy.authorize(:shell_command, %{command: "pwd"}, workspace_root: workspace)
    end
  end
```

The `git -C sub` case is the one that pins the intended `-c` / `-C` asymmetry. If a later edit conflates them, this test is what says so.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/mr_eric/tools/policy_test.exs`

Expected: the git-repointing test FAILS on the `--git-dir` / `--work-tree` / `-c` / `--exec-path` cases, and the program-token test FAILS on `./pwd` and `tmp/pwd`. Both guards PASS.

- [ ] **Step 3: Implement**

Add the second option map next to `@mutating_options`:

```elixir
  # Options that change what the program considers its own root, or that can
  # name another program to execute. `-C <path>` is deliberately absent: its
  # argument is a separate token that ensure_command_paths_allowed/2 already
  # resolves through Policy, and git_subcommand/1 already skips it.
  @root_repointing_options %{
    "git" => [
      ~r/^--git-dir(=|$)/,
      ~r/^--work-tree(=|$)/,
      ~r/^--exec-path(=|$)/,
      ~r/^--namespace(=|$)/,
      ~r/^-c$/
    ]
  }
```

Extend the stage to consult both maps:

```elixir
  defp ensure_program_options_allowed(command) do
    with {:ok, [program | args]} <- command_argv(command) do
      denied =
        Map.get(@mutating_options, program, []) ++
          Map.get(@root_repointing_options, program, [])

      if Enum.any?(args, fn arg -> Enum.any?(denied, &Regex.match?(&1, arg)) end) do
        {:error, :dangerous_command}
      else
        :ok
      end
    end
  end
```

Tighten the program token:

```elixir
  defp ensure_allowed_shell_command(command) do
    with {:ok, [program | args]} <- command_argv(command) do
      cond do
        String.contains?(program, "/") ->
          {:error, :dangerous_command}

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

`Path.basename/1` is dropped: with the `/` guard in front it can no longer differ from `program`, and keeping it would suggest a path is acceptable.

- [ ] **Step 4: Run the tests to verify they pass, and expect one pre-existing assertion to move**

Run: `mix test test/mr_eric/tools/policy_test.exs`

Expected: the new cases PASS, and the pre-existing `test "rejects shell commands that reference paths outside the workspace"` FAILS on its third assertion:

```
git --git-dir=/tmp/.git status
  was {:error, :outside_workspace}, is now {:error, :dangerous_command}
```

This is the Section 3 behaviour delta, not over-rejection — the command is refused either way, and the new reason is the accurate one because `ensure_program_options_allowed/1` runs ahead of the path check. Update that one assertion to `:dangerous_command` with a comment naming the spec, and leave the `cat /etc/passwd` and `cat ../secret.txt` assertions on `:outside_workspace`. If any *other* pre-existing case moves, stop — that is over-rejection and the implementation is wrong.

- [ ] **Step 5: Confirm every end-to-end case is green**

Run: `mix test test/mr_eric/tools/shell_command_test.exs`

Expected: PASS, all cases including all four Spec C-1 ones from Task 1.

- [ ] **Step 6: Run the full suite and the evals**

```bash
mix test
mix mr_eric.evals
```

Expected: PASS. The golden cases issue `shell_command` with `command: "pwd"`, a bare name with no options — unaffected by all three tasks. If an eval fails, the over-rejection guard set is incomplete; fix the implementation, not the golden case.

- [ ] **Step 7: Confirm the frozen attributes really are frozen**

A `git diff | grep <attribute-name>` does **not** work here: the new code carries comments that mention those attributes by name, and they match the grep. Extract the four definitions from both revisions and compare them instead:

```bash
cat > /tmp/extract_attrs.py <<'PY'
import sys, re, subprocess
rev = sys.argv[1]
src = subprocess.run(["git","show",rev+":lib/mr_eric/tools/policy.ex"],
                     capture_output=True, text=True, check=True).stdout
for name in ["allowed_shell_commands","allowed_git_subcommands",
             "forbidden_shell_syntax","dangerous_command_patterns"]:
    m = re.search(r"^  @"+name+r"\s.*?(?=\n\n)", src, re.S | re.M)
    print("@"+name+" =>")
    print(m.group(0) if m else "<<MISSING>>")
PY
python3 /tmp/extract_attrs.py main > /tmp/attrs_main.txt
python3 /tmp/extract_attrs.py HEAD > /tmp/attrs_head.txt
diff -u /tmp/attrs_main.txt /tmp/attrs_head.txt && echo "frozen attributes untouched: OK"
```

Expected: `frozen attributes untouched: OK`, and both files non-empty (36 lines each at the time of writing). Check the line count — if the extraction returns nothing, `diff` reports two empty files as identical and the check silently passes. This is acceptance criterion 6.

- [ ] **Step 8: Commit**

```bash
git add lib/mr_eric/tools/policy.ex test/mr_eric/tools/policy_test.exs
git commit -m "fix(policy): reject root-repointing git options and path-shaped program tokens"
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

In `docs/superpowers/README.md`, change the Spec C-1 row to `**Implemented**` with today's date, and replace "次にやる作業" so it points at **Spec D**.

- [ ] **Step 2: Update the architecture notes**

In `CLAUDE.md`, extend the `:shell_command` bullet under "Safety boundaries":

```markdown
  Argument grammar is bounded too: paths carried inside option tokens (`-fPATH`,
  `--opt=PATH`) are resolved through `Policy`, mutating options (`sed -i`) are rejected
  by argv position-independently, root-repointing options (`git --git-dir`/`--work-tree`/`-c`)
  are rejected per-program, and the program token must be a bare allow-listed name.
```

- [ ] **Step 3: Add the changelog entry**

In `CHANGELOG.md`, under `## [Unreleased]` → `### Security`, add an entry for Spec C-1 naming all three bypasses and noting they pre-dated Spec C.

- [ ] **Step 4: Run the full gate**

Run: `mix precommit`

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/README.md CLAUDE.md CHANGELOG.md
git commit -m "docs: mark Spec C-1 implemented and record the argument grammar boundary"
```

---

## Verification checklist

Run all of these before declaring Spec C-1 done. Each maps to an acceptance criterion in the spec.

| # | Command | Expected |
|---|---------|----------|
| 1 | `mix test test/mr_eric/tools/shell_command_test.exs` | PASS — including the `File.read!` assertion in the `sed` case |
| 2 | `mix test test/mr_eric/tools/policy_test.exs` | PASS — all bypass cases rejected, all over-rejection guards still `{:ok, ...}` |
| 3 | `grep -n 'Path.basename(program)' lib/mr_eric/tools/policy.ex` | no output |
| 4 | Task 4 Step 7's attribute extraction + `diff` | `frozen attributes untouched: OK`, both extracts non-empty |
| 5 | `git status --short priv/evals/` then `mix mr_eric.evals` | no modified golden cases; evals PASS |
| 6 | `mix test` | PASS |
| 7 | `mix precommit` | PASS |
