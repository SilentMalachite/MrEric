defmodule MrEric.LLM.Router do
  @moduledoc """
  Routes a prompt to the provider/model described by an agent spec.
  """

  alias MrEric.LLM.OpenAICompat

  @internal_opts [:max_concurrency, :provider_module, :registry, :server]

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
      {:ok, content} ->
        {:ok, %{agent: agent, content: content || ""}}

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

  defp agent_opts(agent) do
    agent
    |> Map.to_list()
    |> Keyword.put(:agent_name, Map.fetch!(agent, :name))
  end
end
