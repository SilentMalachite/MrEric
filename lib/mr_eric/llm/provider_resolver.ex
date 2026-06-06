defmodule MrEric.LLM.ProviderResolver do
  @moduledoc """
  Resolves the default LLM provider through a boot-time fallback chain.

  When no provider is set explicitly (via `:ai_provider` config or the
  `AI_PROVIDER` environment variable), MrEric prefers a local LLM. At startup it
  probes each provider in `:provider_fallback_chain` order and selects the first
  reachable one. The default chain is `[:lmstudio, :ollama, :openai]`: LM Studio
  first, then Ollama, and finally OpenAI as the unconditional fallback (the
  terminal entry is never probed — it is the "give up and use the cloud" choice).

  The resolved provider is cached in application env and read by
  `MrEric.LLM.Registry`/`MrEric.LLM.OpenAICompat` whenever no explicit provider
  is configured.
  """

  alias MrEric.LLM.OpenAICompat

  @default_chain [:lmstudio, :ollama, :openai]
  @fallback :openai
  @cache_key :resolved_default_provider

  # Short, non-retrying probe so a missing local server does not stall boot.
  @health_req_options [retry: false, receive_timeout: 800, connect_options: [timeout: 800]]

  @doc """
  Returns the cached resolved default provider, or `:openai` if none is cached
  (e.g. before boot resolution or when health checks are disabled).
  """
  def default_provider do
    Application.get_env(:mr_eric, @cache_key, @fallback)
  end

  @doc """
  Resolves the fallback chain and caches the result for `default_provider/0`.

  Returns the static fallback without probing when health checks are disabled
  (via the `:enabled` opt or the `:provider_health_check` config).
  """
  def resolve_and_cache(opts \\ []) do
    if enabled?(opts) do
      resolved = resolve(chain(opts), opts)
      Application.put_env(:mr_eric, @cache_key, resolved)
      resolved
    else
      @fallback
    end
  end

  @doc """
  Returns the first reachable provider in `chain`.

  Every entry except the last is probed via the configured health check; the
  last entry is returned unconditionally as the terminal fallback.

  Pass `:health_check` (a `provider -> boolean` function) to override probing.
  """
  def resolve(chain, opts \\ []) do
    health_check = Keyword.get(opts, :health_check, &default_health_check/1)
    {probe, terminal} = split_terminal(chain)
    Enum.find(probe, terminal, fn provider -> health_check.(provider) end)
  end

  @doc """
  True when a provider is pinned explicitly through config or the environment,
  in which case the fallback chain is irrelevant and need not be probed.
  """
  def explicit_provider_configured? do
    not is_nil(Application.get_env(:mr_eric, :ai_provider)) or
      not is_nil(System.get_env("AI_PROVIDER"))
  end

  defp split_terminal(chain) do
    case List.pop_at(chain, -1) do
      {nil, _} -> {[], @fallback}
      {terminal, probe} -> {probe, terminal}
    end
  end

  defp enabled?(opts) do
    Keyword.get(opts, :enabled, Application.get_env(:mr_eric, :provider_health_check, true))
  end

  defp chain(opts) do
    Keyword.get(opts, :chain) ||
      Application.get_env(:mr_eric, :provider_fallback_chain, @default_chain)
  end

  defp default_health_check(provider) do
    case OpenAICompat.list_models(provider, req_options: @health_req_options) do
      {:ok, _models} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
