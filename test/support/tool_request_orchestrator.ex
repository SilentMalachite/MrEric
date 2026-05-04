defmodule MrEric.ToolRequestOrchestrator do
  @moduledoc false

  def stream(task, pid, _opts) do
    if String.contains?(task, "patch") do
      send(
        pid,
        {:tool_call,
         %{
           tool: :apply_patch,
           tool_call_id: "call-live-patch",
           args: %{
             changes: [
               %{path: "note.txt", before: "old\n", after: "new from patch\n"}
             ]
           }
         }}
      )
    else
      send(
        pid,
        {:tool_call, %{tool: :shell_command, tool_call_id: "call-live", args: %{command: "pwd"}}}
      )
    end

    :ok
  end
end
