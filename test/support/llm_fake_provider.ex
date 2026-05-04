defmodule MrEric.LLM.FakeProvider do
  @moduledoc false

  @behaviour MrEric.LLM.Provider

  @impl true
  def chat_completion(prompt, opts \\ []) do
    name = Keyword.get(opts, :agent_name, "agent")
    model = Keyword.get(opts, :model, "model")

    cond do
      Keyword.get(opts, :fail, false) ->
        {:error, {:fake_failure, name}}

      String.contains?(prompt, "Create a concise implementation plan") ->
        {:ok, "plan from #{model}"}

      String.contains?(prompt, "Produce an implementation draft") ->
        {:ok, "draft from #{name}"}

      String.contains?(prompt, "Review this draft") ->
        {:ok, "review from #{name}"}

      String.contains?(prompt, "Synthesize the final answer") ->
        {:ok, "final from #{model}"}

      true ->
        {:ok, "response from #{name}"}
    end
  end

  @impl true
  def stream_completion(prompt, pid, opts \\ []) do
    case chat_completion(prompt, opts) do
      {:ok, content} ->
        send(pid, {:chunk, content})
        send(pid, {:complete, :ok})
        :ok

      {:error, reason} ->
        send(pid, {:agent_error, reason})
    end
  end

  @impl true
  def list_models(_provider, _opts \\ []) do
    {:ok, [%{"id" => "fake-model"}]}
  end
end
