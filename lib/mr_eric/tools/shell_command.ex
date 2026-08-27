defmodule MrEric.Tools.ShellCommand do
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

  @behaviour MrEric.Tools.Tool

  alias MrEric.Tools.Policy

  @default_env_allowlist ~w(PATH HOME USER LANG LC_ALL TERM TZ TMPDIR SHELL)
  @default_env_pattern_allowlist [~r/^LC_/]

  @impl true
  def name, do: :shell_command

  @impl true
  def description, do: "Run an approved shell command in the workspace."

  @impl true
  def schema do
    %{command: %{type: :string, required: true}}
  end

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

  @doc false
  def build_env, do: build_env(:run)

  defp build_env(_mode) do
    {names, patterns} = resolve_allowlist()
    maybe_warn(names, patterns)
    name_set = MapSet.new(names)

    for {key, value} <- System.get_env() do
      if MapSet.member?(name_set, key) or Enum.any?(patterns, &Regex.match?(&1, key)) do
        {key, value}
      else
        # `nil` tells System.cmd to remove this var from the child env.
        {key, nil}
      end
    end
  end

  defp resolve_allowlist do
    cfg = Application.get_env(:mr_eric, :shell_env_allowlist, [])

    names =
      case cfg[:names] do
        nil -> @default_env_allowlist
        [] -> @default_env_allowlist
        list when is_list(list) -> list
      end

    patterns =
      case cfg[:patterns] do
        nil -> @default_env_pattern_allowlist
        [] -> @default_env_pattern_allowlist
        list when is_list(list) -> list
      end

    {names, patterns}
  end

  @sensitive_name_regex ~r/(?i)(key|token|password|secret|credential)/

  defp maybe_warn(names, patterns) do
    case :persistent_term.get({__MODULE__, :warned}, false) do
      true ->
        :ok

      false ->
        :persistent_term.put({__MODULE__, :warned}, true)

        offenders =
          Enum.filter(names, &Regex.match?(@sensitive_name_regex, &1)) ++
            Enum.filter(patterns, &Regex.match?(@sensitive_name_regex, Regex.source(&1)))

        if offenders != [] do
          require Logger

          Logger.warning(
            "shell_command env allowlist contains likely-sensitive entries: " <>
              Enum.map_join(offenders, ", ", &inspect/1)
          )
        end

        :ok
    end
  end
end
