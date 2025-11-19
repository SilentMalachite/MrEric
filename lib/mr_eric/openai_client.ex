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

  @base_url "https://api.openai.com/v1"

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

    Req.new(
      base_url: @base_url,
      finch: MrEric.Finch,
      headers: [
        {"authorization", "Bearer #{get_api_key()}"},
        {"content-type", "application/json"}
      ]
    )
    |> Req.merge(options)
  end

  defp get_api_key do
    System.get_env("OPENAI_API_KEY") || "dummy_key"
  end

  defp get_default_model do
    Application.get_env(:mr_eric, :openai_model, "gpt-4o")
  end
end
