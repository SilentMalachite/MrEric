defmodule MrEric.LLM.Provider do
  @moduledoc """
  Behaviour for LLM providers used by MrEric.

  Providers should expose chat completions, streaming chat completions,
  and model listing through a small common contract.
  """

  @type provider :: atom() | String.t() | nil
  @type options :: keyword()

  @callback chat_completion(prompt :: String.t(), opts :: options()) ::
              {:ok, String.t() | nil} | {:error, term()}

  @callback stream_completion(prompt :: String.t(), pid :: pid(), opts :: options()) ::
              :ok | term()

  @callback list_models(provider(), opts :: options()) ::
              {:ok, list(map())} | {:error, term()}
end
