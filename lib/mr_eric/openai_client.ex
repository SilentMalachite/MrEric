defmodule MrEric.OpenAIClient do
  @moduledoc """
  OpenAI API client for chat completions.

  Supports all OpenAI models including:
  - GPT-4 models: gpt-4, gpt-4-turbo, gpt-4o, gpt-4o-mini
  - GPT-3.5 models: gpt-3.5-turbo
  - O1 models: o1-preview, o1-mini

  Default model can be configured in config.exs:

      config :mr_eric, openai_model: "gpt-4o"

  Or specify per request:

      OpenAIClient.chat_completion("Hello", model: "gpt-3.5-turbo")
  """

  @default_base_url "https://api.openai.com/v1"

  @doc """
  Performs a chat completion request.

  ## Options

    - `:model` - OpenAI model to use (default: configured in config.exs)

  ## Examples

      chat_completion("Hello, world!")
      chat_completion("Write a haiku", model: "gpt-4")
  """
  def chat_completion(prompt, opts \\ []) do
    model = Keyword.get(opts, :model, get_default_model())

    body = %{
      model: model,
      messages: [
        %{role: "user", content: prompt}
      ]
    }

    request()
    |> Req.post!(url: "/chat/completions", json: body)
    |> Map.get(:body)
    |> get_in(["choices", Access.at(0), "message", "content"])
  end

  @doc """
  Performs a streaming chat completion request.

  ## Options

    - `:model` - OpenAI model to use (default: configured in config.exs)

  ## Examples

      stream_completion("Tell me a story", self())
      stream_completion("Write code", self(), model: "gpt-4-turbo")
  """
  def stream_completion(prompt, pid, opts \\ []) do
    model = Keyword.get(opts, :model, get_default_model())

    body = %{
      model: model,
      stream: true,
      messages: [%{role: "user", content: prompt}]
    }

    request()
    |> Req.post!(
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
              response = Jason.decode!(chunk)
              text = get_in(response, ["choices", Access.at(0), "delta", "content"]) || ""

              if text != "" do
                send(pid, {:chunk, text})
              end
            end
          end)

          {:cont, acc}
      end
    )
  end

  defp request do
    options = Application.get_env(:mr_eric, :openai_req_options, [])

    provider = get_provider()
    base_url = base_url_for(provider)
    api_key = get_api_key(provider)

    headers_base = [
      {"content-type", "application/json"}
    ]

    headers_auth =
      case api_key do
        key when is_binary(key) and byte_size(key) > 0 -> [{"authorization", "Bearer #{key}"}]
        _ -> []
      end

    headers = headers_auth ++ headers_base ++ provider_extra_headers(provider)

    Req.new(
      base_url: base_url,
      finch: MrEric.Finch,
      headers: headers
    )
    |> Req.merge(options)
  end

  defp get_api_key(:openai), do: System.get_env("OPENAI_API_KEY") || "dummy_key"
  defp get_api_key(:grok), do: System.get_env("GROK_API_KEY") || System.get_env("XAI_API_KEY") || "dummy_key"
  defp get_api_key(:openrouter), do: System.get_env("OPENROUTER_API_KEY") || "dummy_key"
  # Local providers typically do not require an API key; allow optional override
  defp get_api_key(:ollama), do: System.get_env("OLLAMA_API_KEY")
  defp get_api_key(:lmstudio), do: System.get_env("LMSTUDIO_API_KEY")

  defp get_provider do
    case (Application.get_env(:mr_eric, :ai_provider) || System.get_env("AI_PROVIDER") || "openai")
         |> String.downcase() do
      "openrouter" -> :openrouter
      "grok" -> :grok
      "xai" -> :grok
      "ollama" -> :ollama
      "lmstudio" -> :lmstudio
      "llstudio" -> :lmstudio
      _ -> :openai
    end
  end

  defp base_url_for(:openai), do: @default_base_url
  defp base_url_for(:grok), do: "https://api.x.ai/v1"
  defp base_url_for(:openrouter), do: "https://openrouter.ai/api/v1"
  defp base_url_for(:ollama), do: System.get_env("OLLAMA_BASE_URL") || "http://localhost:11434/v1"
  defp base_url_for(:lmstudio), do: System.get_env("LMSTUDIO_BASE_URL") || "http://localhost:1234/v1"

  defp provider_extra_headers(:openrouter) do
    referer = System.get_env("OPENROUTER_SITE_URL") || System.get_env("SITE_URL")
    title = System.get_env("OPENROUTER_APP_NAME") || "MrEric"

    Enum.reject([
      if(referer, do: {"HTTP-Referer", referer}),
      {"X-Title", title}
    ], &is_nil/1)
  end

  defp provider_extra_headers(_), do: []

  defp get_default_model do
    Application.get_env(:mr_eric, :openai_model, "gpt-4o")
  end
end
