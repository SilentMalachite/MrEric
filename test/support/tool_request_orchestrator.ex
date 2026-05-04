defmodule MrEric.ToolRequestOrchestrator do
  @moduledoc false

  def stream(_task, pid, _opts) do
    send(
      pid,
      {:tool_call, %{tool: :shell_command, tool_call_id: "call-live", args: %{command: "pwd"}}}
    )

    :ok
  end
end
