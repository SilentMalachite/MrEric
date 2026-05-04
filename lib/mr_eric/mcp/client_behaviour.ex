defmodule MrEric.MCP.ClientBehaviour do
  @moduledoc """
  Behaviour for future MCP clients.

  Phase 5B defines the extension boundary only. Concrete clients can later
  connect to stdio, HTTP, or in-process MCP servers behind this contract.
  """

  @type tool_descriptor :: map()
  @type tool_result :: map()

  @callback list_tools(keyword()) :: {:ok, [tool_descriptor()]} | {:error, term()}
  @callback call_tool(String.t(), map(), keyword()) :: {:ok, tool_result()} | {:error, term()}
end
