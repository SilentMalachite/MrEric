defmodule MrEric.OpenAIClient do
  @moduledoc false

  @base_url "https://api.openai.com/v1"

  def chat_completion(prompt, model \\ "gpt-4o") do
    body = %{
      model: model,
      messages: [
        %{role: "user", content: prompt}
      ]
    }

    request()
    |> Req.post!(url: "/chat/completions", json: body)
    |> get_in([:body, "choices", Access.at(0), "message", "content"])
  end

  def stream_completion(prompt, pid, model \\ "gpt-4o") do
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
              text = get_in(response, ["choices", 0, "delta", "content"]) || ""

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
    Req.new(
      base_url: @base_url,
      finch: MrEric.Finch,
      headers: [
        {"authorization", "Bearer #{System.fetch_env!("OPENAI_API_KEY")}"},
        {"content-type", "application/json"}
      ]
    )
  end
end
