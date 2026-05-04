defmodule MrEric.LLM.OpenAICompat do
  @moduledoc """
  OpenAI-compatible LLM provider.

  Supports OpenAI, Grok/xAI, OpenRouter, Ollama, and LM Studio through
  `/v1/chat/completions` and `/v1/models` compatible endpoints.
  """

  @behaviour MrEric.LLM.Provider

  @default_base_url "https://api.openai.com/v1"

  @impl true
  def chat_completion(prompt, opts \\ []) do
    provider = provider_from_opts(opts)
    model = Keyword.get(opts, :model, get_default_model())

    body = %{
      model: model,
      messages: [
        %{role: "user", content: prompt}
      ]
    }

    with {:ok, req} <- request(provider, opts),
         {:ok, %{status: 200, body: body}} <- Req.post(req, url: "/chat/completions", json: body) do
      {:ok, get_in(body, ["choices", Access.at(0), "message", "content"])}
    else
      {:ok, %{status: status, body: body}} -> {:error, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def stream_completion(prompt, pid, opts \\ []) do
    provider = provider_from_opts(opts)
    model = Keyword.get(opts, :model, get_default_model())

    body = %{
      model: model,
      stream: true,
      messages: [%{role: "user", content: prompt}]
    }

    case request(provider, opts) do
      {:ok, req} ->
        Req.post(req,
          url: "/chat/completions",
          json: body,
          into: fn
            {:data, data}, acc ->
              data
              |> String.split("data: ")
              |> Enum.map(&String.trim/1)
              |> Enum.reject(&(&1 == ""))
              |> Enum.each(fn chunk ->
                if chunk == "[DONE]" do
                  send(pid, {:complete, :ok})
                else
                  case Jason.decode(chunk) do
                    {:ok, response} ->
                      text = get_in(response, ["choices", Access.at(0), "delta", "content"]) || ""
                      if text != "", do: send(pid, {:chunk, text})

                    _ ->
                      :ok
                  end
                end
              end)

              {:cont, acc}
          end
        )
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> send(pid, {:agent_error, reason})
        end

      {:error, reason} ->
        send(pid, {:agent_error, reason})
    end
  end

  @impl true
  def list_models(provider, opts \\ []) do
    provider = normalize_provider(provider)

    with {:ok, req} <- request(provider, opts),
         {:ok, %{status: 200, body: body}} <- Req.get(req, url: "/models") do
      {:ok, Map.get(body, "data", [])}
    else
      {:ok, %{status: status, body: body}} -> {:error, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(provider, opts) do
    req_options =
      Application.get_env(:mr_eric, :openai_req_options, [])
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    base_url = Keyword.get(opts, :base_url, base_url_for(provider))
    api_key = Keyword.get(opts, :api_key) || get_api_key(provider)

    if is_nil(api_key) and provider in [:openai, :grok, :openrouter] do
      {:error, :missing_api_key}
    else
      headers_base = [{"content-type", "application/json"}]

      headers_auth =
        case api_key do
          key when is_binary(key) and byte_size(key) > 0 -> [{"authorization", "Bearer #{key}"}]
          _ -> []
        end

      headers = headers_auth ++ headers_base ++ provider_extra_headers(provider)

      req =
        Req.new(
          base_url: base_url,
          finch: MrEric.Finch,
          headers: headers
        )
        |> Req.merge(req_options)

      {:ok, req}
    end
  end

  defp provider_from_opts(opts) do
    opts
    |> Keyword.get(:provider, configured_provider())
    |> normalize_provider()
  end

  defp configured_provider do
    Application.get_env(:mr_eric, :ai_provider) || System.get_env("AI_PROVIDER") || "openai"
  end

  defp normalize_provider(provider) when provider in [nil, ""],
    do: normalize_provider(configured_provider())

  defp normalize_provider(provider) when is_atom(provider) do
    provider
    |> Atom.to_string()
    |> normalize_provider()
  end

  defp normalize_provider(provider) when is_binary(provider) do
    case String.downcase(provider) do
      "openrouter" -> :openrouter
      "grok" -> :grok
      "xai" -> :grok
      "ollama" -> :ollama
      "lmstudio" -> :lmstudio
      "llstudio" -> :lmstudio
      _ -> :openai
    end
  end

  defp get_api_key(:openai), do: System.get_env("OPENAI_API_KEY")
  defp get_api_key(:grok), do: System.get_env("GROK_API_KEY") || System.get_env("XAI_API_KEY")
  defp get_api_key(:openrouter), do: System.get_env("OPENROUTER_API_KEY")
  defp get_api_key(:ollama), do: System.get_env("OLLAMA_API_KEY")
  defp get_api_key(:lmstudio), do: System.get_env("LMSTUDIO_API_KEY")

  defp base_url_for(:openai), do: @default_base_url
  defp base_url_for(:grok), do: "https://api.x.ai/v1"
  defp base_url_for(:openrouter), do: "https://openrouter.ai/api/v1"
  defp base_url_for(:ollama), do: System.get_env("OLLAMA_BASE_URL") || "http://localhost:11434/v1"

  defp base_url_for(:lmstudio),
    do: System.get_env("LMSTUDIO_BASE_URL") || "http://localhost:1234/v1"

  defp provider_extra_headers(:openrouter) do
    referer = System.get_env("OPENROUTER_SITE_URL") || System.get_env("SITE_URL")
    title = System.get_env("OPENROUTER_APP_NAME") || "MrEric"

    Enum.reject(
      [
        if(referer, do: {"HTTP-Referer", referer}),
        {"X-Title", title}
      ],
      &is_nil/1
    )
  end

  defp provider_extra_headers(_), do: []

  defp get_default_model do
    Application.get_env(:mr_eric, :openai_model, "gpt-4o")
  end
end
