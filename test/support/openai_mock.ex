defmodule MrEric.OpenAIMock do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.request_path do
      "/v1/chat/completions" ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        prompt = get_in(params, ["messages", Access.at(0), "content"]) || ""
        model = Map.get(params, "model")

        content =
          cond do
            String.contains?(prompt, "report provider") ->
              "provider:#{provider_from_conn(conn)} model:#{model}"

            String.contains?(prompt, "report model") ->
              "model:#{model}"

            String.contains?(prompt, "plan") ->
              "1. Create a controller\n2. Add a route"

            String.contains?(prompt, "Generate Elixir code") ->
              """
              defmodule MrEricWeb.MyController do
                use MrEricWeb, :controller
                def index(conn, _params), do: text(conn, "Hello")
              end
              """

            true ->
              "Mock response"
          end

        response = %{
          "choices" => [
            %{
              "message" => %{
                "content" => content
              },
              "delta" => %{
                "content" => content
              }
            }
          ]
        }

        if Map.get(params, "stream") do
          send_sse_response(conn, content)
        else
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(response))
        end

      "/v1/models" ->
        response = %{
          "object" => "list",
          "data" => [
            %{"id" => "gpt-4o", "object" => "model"},
            %{"id" => "gpt-4o-mini", "object" => "model"}
          ]
        }

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))

      _ ->
        Plug.Conn.send_resp(conn, 404, "Not Found")
    end
  end

  defp provider_from_conn(%Plug.Conn{host: "api.x.ai"}), do: "grok"
  defp provider_from_conn(%Plug.Conn{host: "openrouter.ai"}), do: "openrouter"
  defp provider_from_conn(%Plug.Conn{host: "localhost", port: 11_434}), do: "ollama"
  defp provider_from_conn(%Plug.Conn{host: "localhost", port: 1234}), do: "lmstudio"
  defp provider_from_conn(_conn), do: "openai"

  defp send_sse_response(conn, content) do
    # Minimal SSE simulation
    conn = Plug.Conn.send_chunked(conn, 200)

    chunk_data = %{
      "choices" => [%{"delta" => %{"content" => content}}]
    }

    chunk = "data: #{Jason.encode!(chunk_data)}\n\n"
    done = "data: [DONE]\n\n"

    {:ok, conn} = Plug.Conn.chunk(conn, chunk)
    {:ok, conn} = Plug.Conn.chunk(conn, done)
    conn
  end
end
