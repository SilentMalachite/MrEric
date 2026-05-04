defmodule MrEric.MCP.ToolAdapterTest do
  use ExUnit.Case, async: true

  alias MrEric.MCP.ToolAdapter

  defmodule FakeClient do
    @behaviour MrEric.MCP.ClientBehaviour

    @impl true
    def list_tools(_opts) do
      {:ok,
       [
         %{
           "name" => "project_search",
           "description" => "Search project context",
           "inputSchema" => %{
             "type" => "object",
             "properties" => %{"query" => %{"type" => "string"}}
           }
         }
       ]}
    end

    @impl true
    def call_tool(name, args, _opts) do
      {:ok, %{tool: name, args: args, content: [%{type: "text", text: "ok"}]}}
    end
  end

  test "normalizes MCP tool descriptors into tool-like schemas" do
    assert {:ok, [tool]} = ToolAdapter.list_tools(FakeClient)

    assert tool.name == "mcp:project_search"
    assert tool.description == "Search project context"
    assert tool.schema["type"] == "object"
  end

  test "calls an MCP client through the adapter" do
    assert {:ok, result} =
             ToolAdapter.call_tool(FakeClient, "project_search", %{"query" => "approval"})

    assert result.tool == "project_search"
    assert result.args == %{"query" => "approval"}
    assert [%{text: "ok"}] = result.content
  end
end
