defmodule MrEric.Tools.ShellCommand do
  @moduledoc """
  Runs an approved shell command from the workspace root.
  """

  @behaviour MrEric.Tools.Tool

  alias MrEric.Tools.Policy

  @secret_env_names ~w(
    OPENAI_API_KEY
    GROK_API_KEY
    XAI_API_KEY
    OPENROUTER_API_KEY
    ANTHROPIC_API_KEY
    GOOGLE_API_KEY
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    AWS_SESSION_TOKEN
  )

  @impl true
  def name, do: :shell_command

  @impl true
  def description, do: "Run an approved shell command in the workspace."

  @impl true
  def schema do
    %{
      command: %{type: :string, required: true}
    }
  end

  @impl true
  def run(args, opts) do
    command = Policy.arg(args, :command) |> to_string()
    workspace = Policy.workspace_root(opts)

    {output, exit_status} =
      System.cmd("sh", ["-lc", command],
        cd: workspace,
        stderr_to_stdout: true,
        env: scrubbed_env()
      )

    {:ok,
     %{
       command: command,
       output: output,
       exit_status: exit_status
     }}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp scrubbed_env do
    Enum.map(@secret_env_names, &{&1, nil})
  end
end
