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

  # Every case below gets its own workspace *and* its own outside dir. Revision 1's
  # probe was contaminated across cases — an earlier in-place sed rewrote the fixture,
  # so a later grep reported exit 1 and looked blocked when it was not.
  defp outside_dir do
    dir = Path.join(System.tmp_dir!(), "mr-eric-outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp marker_hook(workspace, marker_path) do
    hook = Path.join(workspace, "pre_hook")
    File.write!(hook, "#!/bin/sh\necho ran > #{marker_path}\ncat \"$1\"\n")
    File.chmod!(hook, 0o755)
    hook
  end

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

    # --- Revision 2: unknown options must not fail open ---

    test "rg --pre cannot execute a child process", %{workspace: workspace} do
      outside = outside_dir()
      marker = Path.join(outside, "HOOK_RAN")
      marker_hook(workspace, marker)
      File.write!(Path.join(workspace, "inside.txt"), "needle\n")

      assert {:error, :dangerous_command} =
               ShellCommand.run(%{command: "rg --pre=./pre_hook needle inside.txt"},
                 workspace_root: workspace
               )

      refute File.exists?(marker)
    end

    test "rg --hostname-bin cannot execute a child process", %{workspace: workspace} do
      outside = outside_dir()
      marker = Path.join(outside, "HOOK_RAN")
      marker_hook(workspace, marker)
      File.write!(Path.join(workspace, "inside.txt"), "needle\n")

      assert {:error, :dangerous_command} =
               ShellCommand.run(%{command: "rg --hostname-bin=./pre_hook needle inside.txt"},
                 workspace_root: workspace
               )

      refute File.exists?(marker)
    end

    test "rg -L cannot follow a symlink out of the workspace", %{workspace: workspace} do
      outside = outside_dir()
      File.write!(Path.join(outside, "SECRET.txt"), "OUTSIDE_ONLY\n")
      File.ln_s!(Path.join(outside, "SECRET.txt"), Path.join(workspace, "link.txt"))

      assert {:error, :dangerous_command} =
               ShellCommand.run(%{command: "rg -L OUTSIDE_ONLY ."}, workspace_root: workspace)
    end

    test "ls -LR cannot dereference symlinks", %{workspace: workspace} do
      assert {:error, :dangerous_command} =
               ShellCommand.run(%{command: "ls -LR ."}, workspace_root: workspace)
    end

    test "git --config-env is refused", %{workspace: workspace} do
      System.cmd("git", ["init", "-q"], cd: workspace, stderr_to_stdout: true)

      assert {:error, :dangerous_command} =
               ShellCommand.run(
                 %{command: "git --config-env=core.pager=MR_ERIC_HOOK status --short"},
                 workspace_root: workspace
               )
    end

    test "git diff --output cannot truncate a file", %{workspace: workspace} do
      System.cmd("git", ["init", "-q"], cd: workspace, stderr_to_stdout: true)
      target = Path.join(workspace, "target.txt")
      File.write!(target, "KEEP-ME\n")

      assert {:error, :dangerous_command} =
               ShellCommand.run(%{command: "git diff --output=target.txt"},
                 workspace_root: workspace
               )

      assert File.read!(target) == "KEEP-ME\n"
    end

    # --- Revision 2: bundled short options must decompose ---

    test "sed is off the allow-list, bundled -i included", %{workspace: workspace} do
      target = Path.join(workspace, "inside.txt")

      for command <- [
            "sed -Ei.bak s/foo/bar/ inside.txt",
            "sed -ni.bak s/foo/bar/p inside.txt",
            "sed -i.bak s/foo/bar/ inside.txt",
            "sed -n 1,5p inside.txt"
          ] do
        File.write!(target, "foo\n")

        assert {:error, :dangerous_command} =
                 ShellCommand.run(%{command: command}, workspace_root: workspace)

        assert File.read!(target) == "foo\n"
        refute File.exists?(Path.join(workspace, "inside.txt.bak"))
      end
    end

    test "sed cannot write outside the workspace via its script language", %{
      workspace: workspace
    } do
      outside = outside_dir()
      File.write!(Path.join(workspace, "inside.txt"), "foo\n")
      rel = Path.join("..", Path.basename(outside))

      assert {:error, :dangerous_command} =
               ShellCommand.run(%{command: "sed -n 1w#{rel}/sed_marker inside.txt"},
                 workspace_root: workspace
               )

      refute File.exists?(Path.join(outside, "sed_marker"))
    end

    test "a bundled -f still resolves its real value", %{workspace: workspace} do
      outside = outside_dir()
      File.write!(Path.join(outside, "patterns"), "needle\n")
      File.write!(Path.join(workspace, "inside.txt"), "foo\nneedle\n")
      rel = Path.join("..", Path.basename(outside))

      for command <- [
            "grep -nf#{rel}/patterns inside.txt",
            "grep -f#{rel}/patterns inside.txt",
            "grep --file=#{rel}/patterns inside.txt",
            "grep -f #{rel}/patterns inside.txt",
            "rg -nf#{rel}/patterns inside.txt"
          ] do
        assert {:error, :outside_workspace} =
                 ShellCommand.run(%{command: command}, workspace_root: workspace)
      end
    end

    # --- Revision 2: values that are not paths must not be resolved as paths ---

    test "a pattern value is not treated as a path", %{workspace: workspace} do
      File.write!(Path.join(workspace, "inside.txt"), "foo\n")

      for command <- [
            "grep -e/etc/passwd inside.txt",
            "grep --regexp=/etc/passwd inside.txt",
            "grep -- -f../needle inside.txt"
          ] do
        assert {:ok, %{exit_status: _}} =
                 ShellCommand.run(%{command: command}, workspace_root: workspace)
      end
    end

    test "an operand after the pattern is still a path", %{workspace: workspace} do
      assert {:error, :outside_workspace} =
               ShellCommand.run(%{command: "grep needle /etc/passwd"}, workspace_root: workspace)
    end

    test "the common read-only forms still work", %{workspace: workspace} do
      File.write!(Path.join(workspace, "note.txt"), "hello\n")
      File.mkdir_p!(Path.join(workspace, "sub"))
      System.cmd("git", ["init", "-q"], cd: workspace, stderr_to_stdout: true)

      for command <- [
            "pwd",
            "pwd -P",
            "ls -la",
            "ls --color=auto",
            "cat note.txt",
            "cat -n note.txt",
            "grep -rn hello note.txt",
            "git status --short",
            "git -C sub status --short",
            "git diff --stat"
          ] do
        assert {:ok, %{exit_status: 0}} =
                 ShellCommand.run(%{command: command}, workspace_root: workspace),
               "expected #{command} to be allowed and succeed"
      end
    end
  end
end
