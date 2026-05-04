defmodule MrEric.LLM.Router do
  @moduledoc """
  Routes a prompt to the provider/model described by an agent spec.
  """

  alias MrEric.LLM.OpenAICompat

  @internal_opts [
    :max_concurrency,
    :chunk_overlap,
    :chunk_size,
    :ignore_dirs,
    :include_extensions,
    :max_file_bytes,
    :paths,
    :provider_module,
    :rag_context,
    :rag_enabled,
    :rag_enabled?,
    :rag_index,
    :rag_max_context_chars,
    :rag_module,
    :rag_paths,
    :rag_top_k,
    :registry,
    :server,
    :workspace_root
  ]

  @doc """
  Completes a prompt using the given agent spec.

  Provider errors and unexpected failures are returned as tagged errors instead
  of being raised, which lets orchestration continue with other agents.
  """
  def complete(prompt, agent, opts \\ []) when is_binary(prompt) and is_map(agent) do
    provider_module =
      Keyword.get(opts, :provider_module) ||
        Application.get_env(:mr_eric, :llm_provider_module, OpenAICompat)

    llm_opts =
      opts
      |> Keyword.drop(@internal_opts)
      |> Keyword.merge(agent_opts(agent))

    case safe_completion(provider_module, prompt, llm_opts) do
      {:ok, response} ->
        completion = normalize_completion(response)
        {:ok, completion |> Map.put(:agent, agent)}

      {:error, reason} ->
        {:error, %{agent: agent, reason: reason}}
    end
  end

  defp safe_completion(provider_module, prompt, opts) do
    provider_module.chat_completion(prompt, opts)
  rescue
    error -> {:error, {error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_completion(%{} = response) do
    response =
      if Map.has_key?(response, "choices") or Map.has_key?(response, :choices) do
        OpenAICompat.parse_chat_message(response)
      else
        response
      end

    %{
      content: normalize_content(Map.get(response, :content) || Map.get(response, "content")),
      tool_calls: Map.get(response, :tool_calls) || Map.get(response, "tool_calls") || []
    }
  end

  defp normalize_completion(content) do
    %{content: normalize_content(content), tool_calls: []}
  end

  defp normalize_content(nil), do: ""
  defp normalize_content(content) when is_binary(content), do: content
  defp normalize_content(content), do: inspect(content)

  defp agent_opts(agent) do
    agent
    |> Map.to_list()
    |> Keyword.put(:agent_name, Map.fetch!(agent, :name))
  end
end
