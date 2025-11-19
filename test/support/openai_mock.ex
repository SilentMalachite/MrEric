defmodule MrEric.OpenAIMock do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.request_path do
      "/v1/chat/completions" ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        prompt = get_in(params, ["messages", Access.at(0), "content"]) || ""

        content =
          cond do
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
              "delta" => %{ # For streaming
                "content" => content
              }
            }
          ]
        }

        # Handle streaming if requested?
        # The client implementation handles streaming differently (receiving chunks).
        # Testing streaming with a simple plug is harder because we need to send chunks.
        # For now, let's focus on normal requests.
        # If stream=true is in params, we might need to simulate SSE.
        
        if Map.get(params, "stream") do
           send_sse_response(conn, content)
        else
           conn
           |> Plug.Conn.put_resp_header("content-type", "application/json")
           |> Plug.Conn.send_resp(200, Jason.encode!(response))
        end

      _ ->
        Plug.Conn.send_resp(conn, 404, "Not Found")
    end
  end

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
