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
