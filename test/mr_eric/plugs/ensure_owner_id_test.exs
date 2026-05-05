defmodule MrEric.Plugs.EnsureOwnerIdTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias MrEric.Plugs.EnsureOwnerId

  @opts EnsureOwnerId.init([])

  defp conn_with_session(initial_session) do
    :get
    |> conn("/")
    |> Plug.Test.init_test_session(initial_session)
  end

  test "mints an owner_id when session is empty" do
    conn = conn_with_session(%{}) |> EnsureOwnerId.call(@opts)

    assert get_session(conn, :owner_id) |> is_binary()
    assert byte_size(get_session(conn, :owner_id)) >= 16
  end

  test "leaves an existing owner_id untouched" do
    conn = conn_with_session(%{"owner_id" => "existing"}) |> EnsureOwnerId.call(@opts)

    assert get_session(conn, :owner_id) == "existing"
  end

  test "owner_ids minted in two empty sessions differ" do
    a = conn_with_session(%{}) |> EnsureOwnerId.call(@opts) |> get_session(:owner_id)
    b = conn_with_session(%{}) |> EnsureOwnerId.call(@opts) |> get_session(:owner_id)

    assert a != b
  end

  test "session_key/0 returns :owner_id" do
    assert EnsureOwnerId.session_key() == :owner_id
  end
end
