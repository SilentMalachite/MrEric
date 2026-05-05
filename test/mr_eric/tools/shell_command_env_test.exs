defmodule MrEric.Tools.ShellCommandEnvTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MrEric.Tools.ShellCommand

  setup do
    System.put_env("FAKE_LEAK_TOKEN", "definitely-leaked")
    on_exit(fn -> System.delete_env("FAKE_LEAK_TOKEN") end)
    # Reset the once-per-boot warn guard so each test gets a clean slate.
    :persistent_term.erase({MrEric.Tools.ShellCommand, :warned})
    :ok
  end

  test "default allow-list strips arbitrary env vars" do
    assert {:ok, %{output: output}} =
             ShellCommand.run(%{"command" => "sh -c 'echo FAKE_LEAK_TOKEN=$FAKE_LEAK_TOKEN'"}, [])

    refute output =~ "definitely-leaked"
    assert output =~ "FAKE_LEAK_TOKEN="
  end

  test "default allow-list keeps PATH" do
    assert {:ok, %{output: output}} =
             ShellCommand.run(%{"command" => "sh -c 'echo PATH=$PATH'"}, [])

    assert output =~ "/"
  end

  test "configured names allow-list lets a custom var through" do
    Application.put_env(:mr_eric, :shell_env_allowlist,
      names: ~w(PATH HOME USER LANG LC_ALL TERM TZ TMPDIR SHELL FAKE_LEAK_TOKEN))
    on_exit(fn -> Application.delete_env(:mr_eric, :shell_env_allowlist) end)

    assert {:ok, %{output: output}} =
             ShellCommand.run(%{"command" => "sh -c 'echo X=$FAKE_LEAK_TOKEN'"}, [])

    assert output =~ "X=definitely-leaked"
  end

  test "configured pattern allow-list lets matching vars through" do
    System.put_env("MR_ERIC_TEST_VAR", "ok-value")
    on_exit(fn -> System.delete_env("MR_ERIC_TEST_VAR") end)

    Application.put_env(:mr_eric, :shell_env_allowlist,
      names: ~w(PATH HOME USER LANG LC_ALL TERM TZ TMPDIR SHELL),
      patterns: [~r/^MR_ERIC_/])
    on_exit(fn -> Application.delete_env(:mr_eric, :shell_env_allowlist) end)

    assert {:ok, %{output: output}} =
             ShellCommand.run(%{"command" => "sh -c 'echo Y=$MR_ERIC_TEST_VAR'"}, [])

    assert output =~ "Y=ok-value"
  end

  test "empty configured names falls back to defaults (PATH still passes)" do
    Application.put_env(:mr_eric, :shell_env_allowlist, names: [], patterns: [])
    on_exit(fn -> Application.delete_env(:mr_eric, :shell_env_allowlist) end)

    assert {:ok, %{output: output}} =
             ShellCommand.run(%{"command" => "sh -c 'echo PATH=$PATH'"}, [])

    assert output =~ "/"
  end

  test "warns once when a configured name looks sensitive" do
    Application.put_env(:mr_eric, :shell_env_allowlist,
      names: ~w(PATH GITHUB_TOKEN), patterns: [])
    on_exit(fn -> Application.delete_env(:mr_eric, :shell_env_allowlist) end)
    on_exit(fn -> :persistent_term.erase({MrEric.Tools.ShellCommand, :warned}) end)

    log =
      capture_log(fn ->
        ShellCommand.run(%{"command" => "sh -c 'echo X'"}, [])
      end)

    assert log =~ "GITHUB_TOKEN"
    assert log =~ "likely-sensitive"
  end
end
