defmodule MrEric.OpenAIClient do
  @moduledoc """
  Backward-compatible OpenAI client facade.

  New LLM provider code lives under `MrEric.LLM`. Existing callers can keep
  using this module while passing provider/model options through to the LLM
  layer.
  """

  alias MrEric.LLM.OpenAICompat

  @doc """
  Performs a chat completion request.

  ## Options

    - `:provider` - Provider to use, such as `:openai`, `:openrouter`, or `:ollama`
    - `:model` - Model to use
  """
  def chat_completion(prompt, opts \\ []) do
    OpenAICompat.chat_completion(prompt, opts)
  end

  @doc """
  Performs a streaming chat completion request.

  Streaming chunks are sent to `pid` as `{:chunk, text}` and completion as
  `{:complete, :ok}`.
  """
  def stream_completion(prompt, pid, opts \\ []) do
    OpenAICompat.stream_completion(prompt, pid, opts)
  end

  @doc """
  Lists models from an OpenAI-compatible `/v1/models` endpoint.
  """
  def list_models(provider, opts \\ []) do
    OpenAICompat.list_models(provider, opts)
  end
end
