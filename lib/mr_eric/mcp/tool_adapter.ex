defmodule MrEric.MCP.ToolAdapter do
  @moduledoc """
  Adapts MCP tool descriptors and calls into MrEric's tool-shaped maps.
  """

  def list_tools(client, opts \\ []) do
    client
    |> safe_call(:list_tools, [opts])
    |> case do
      {:ok, tools} when is_list(tools) -> {:ok, Enum.map(tools, &normalize_tool/1)}
      {:ok, _other} -> {:error, :invalid_tools}
      {:error, reason} -> {:error, reason}
    end
  end

  def call_tool(client, name, args, opts \\ [])

  def call_tool(client, name, args, opts) when is_map(args) do
    mcp_name = mcp_name(name)

    client
    |> safe_call(:call_tool, [mcp_name, args, opts])
    |> case do
      {:ok, result} when is_map(result) -> {:ok, normalize_result(result)}
      {:ok, result} -> {:ok, %{content: result}}
      {:error, reason} -> {:error, reason}
    end
  end

  def call_tool(_client, _name, _args, _opts), do: {:error, :invalid_args}

  defp normalize_tool(tool) when is_map(tool) do
    name = tool |> value(:name) |> to_string()

    %{
      name: "mcp:" <> name,
      mcp_name: name,
      description: tool |> value(:description) |> string_or_default("MCP tool #{name}"),
      schema:
        value(tool, :input_schema) || value(tool, :inputSchema) || value(tool, :schema) || %{}
    }
  end

  defp normalize_tool(tool) do
    name = to_string(tool)

    %{
      name: "mcp:" <> name,
      mcp_name: name,
      description: "MCP tool #{name}",
      schema: %{}
    }
  end

  defp normalize_result(result) do
    Map.new(result, fn {key, value} -> {normalize_key(key), normalize_value(value)} end)
  end

  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value) when is_map(value), do: normalize_result(value)
  defp normalize_value(value), do: value

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key("content"), do: :content
  defp normalize_key("isError"), do: :is_error
  defp normalize_key("is_error"), do: :is_error
  defp normalize_key("text"), do: :text
  defp normalize_key("tool"), do: :tool
  defp normalize_key("type"), do: :type
  defp normalize_key(key), do: key

  defp value(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value(map, key) when is_binary(key), do: Map.get(map, key)

  defp string_or_default(value, _default) when is_binary(value) and value != "", do: value
  defp string_or_default(_value, default), do: default

  defp mcp_name(name) when is_atom(name), do: Atom.to_string(name)

  defp mcp_name("mcp:" <> name), do: name
  defp mcp_name(name) when is_binary(name), do: name
  defp mcp_name(name), do: to_string(name)

  defp safe_call(module, function, args) do
    apply(module, function, args)
  rescue
    error -> {:error, {error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
