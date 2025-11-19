defmodule MrEricWeb.AgentLiveTest do
  use MrEricWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders agent interface", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Enter task for AI agent"
  end
end
