defmodule MrEric.Plugs.EnsureOwnerId do
  @moduledoc """
  Ensures the browser session has a stable `owner_id` for Run authorisation.

  Idempotent: if the session already has one, leaves it alone. If not, mints
  a 16-byte cryptographically random base64url string and stores it.

  This is the single source of session-bound run ownership in dev/local mode.
  """

  import Plug.Conn

  @session_key :owner_id

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, @session_key) do
      nil ->
        owner_id = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
        put_session(conn, @session_key, owner_id)

      _existing ->
        conn
    end
  end

  def session_key, do: @session_key
end
