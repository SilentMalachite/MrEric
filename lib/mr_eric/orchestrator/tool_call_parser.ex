defmodule MrEric.Orchestrator.ToolCallParser do
  @moduledoc """
  Extracts safe, normalized tool requests from LLM responses.
  """

  def extract(response) do
    response
    |> openai_tool_calls()
    |> case do
      [] -> internal_tool_call(response)
      calls -> Enum.map(calls, &normalize_openai_tool_call/1)
    end
  end

  defp openai_tool_calls(%{} = response) do
    response
    |> get_any([:tool_calls, "tool_calls"])
    |> case do
      calls when is_list(calls) ->
        calls

      _other ->
        response
        |> get_in(["choices", Access.at(0), "message", "tool_calls"])
        |> case do
          calls when is_list(calls) -> calls
          _other -> []
        end
    end
  end

  defp openai_tool_calls(_response), do: []

  defp normalize_openai_tool_call(call) when is_map(call) do
    function = get_any(call, [:function, "function"]) || %{}
    tool_call_id = get_any(call, [:id, "id"]) || new_id()
    tool = get_any(function, [:name, "name"])
    arguments = get_any(function, [:arguments, "arguments"]) || %{}

    case decode_arguments(arguments) do
      {:ok, args} ->
        %{
          tool_call_id: tool_call_id,
          tool: tool,
          tool_name: tool,
          input: args,
          args: args,
          reason: get_any(call, [:reason, "reason"])
        }

      {:error, reason} ->
        %{
          tool_call_id: tool_call_id,
          tool: tool,
          tool_name: tool,
          input: %{},
          args: %{},
          error: reason
        }
    end
  end

  defp normalize_openai_tool_call(_call) do
    %{
      tool_call_id: new_id(),
      tool: nil,
      tool_name: nil,
      input: %{},
      args: %{},
      error: :invalid_tool_call
    }
  end

  defp internal_tool_call(response) do
    content = response_content(response)

    with true <- is_binary(content),
         trimmed when trimmed != "" <- String.trim(content),
         true <- String.starts_with?(trimmed, "{"),
         {:ok, decoded} <- Jason.decode(trimmed),
         true <- is_map(decoded),
         tool when is_binary(tool) <- Map.get(decoded, "tool") do
      args = Map.get(decoded, "input") || Map.get(decoded, "args") || %{}

      [
        %{
          tool_call_id: Map.get(decoded, "id") || Map.get(decoded, "tool_call_id") || new_id(),
          tool: tool,
          tool_name: tool,
          input: normalize_args(args),
          args: normalize_args(args),
          reason: Map.get(decoded, "reason")
        }
      ]
    else
      _other -> []
    end
  end

  defp response_content(%{} = response), do: get_any(response, [:content, "content"])
  defp response_content(content) when is_binary(content), do: content
  defp response_content(_response), do: nil

  defp decode_arguments(args) when is_map(args), do: {:ok, normalize_args(args)}

  defp decode_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> {:ok, normalize_args(decoded)}
      {:ok, _decoded} -> {:error, :invalid_tool_arguments}
      {:error, _error} -> {:error, :invalid_tool_arguments}
    end
  end

  defp decode_arguments(_args), do: {:error, :invalid_tool_arguments}

  defp normalize_args(args) when is_map(args), do: args
  defp normalize_args(_args), do: %{}

  defp get_any(map, keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp new_id do
    "tool-call-" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end
end
