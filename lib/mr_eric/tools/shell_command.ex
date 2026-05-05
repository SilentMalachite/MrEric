defmodule MrEric.Tools.ShellCommand do
  @moduledoc """
  Runs an approved shell command from the workspace root.

  The child process inherits only environment variables on the configured
  allow-list. Every other parent env var is explicitly unset (System.cmd
  honours nil values as removals). Defaults are intentionally minimal;
  expand via `config :mr_eric, :shell_env_allowlist, names: [...], patterns: [...]`.
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
    command = Policy.arg(args, :command) |> to_string()
    workspace = Policy.workspace_root(opts)
    env = build_env()

    {output, exit_status} =
      System.cmd("sh", ["-lc", command],
        cd: workspace,
        stderr_to_stdout: true,
        env: env
      )

    {:ok, %{command: command, output: output, exit_status: exit_status}}
  rescue
    error -> {:error, Exception.message(error)}
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
