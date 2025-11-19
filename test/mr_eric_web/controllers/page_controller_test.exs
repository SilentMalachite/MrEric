defmodule MrEricWeb.PageControllerTest do
  use MrEricWeb.ConnCase

  test "GET /home", %{conn: conn} do
    conn = 
      conn
      |> Phoenix.Controller.put_format("html")
      |> Plug.Conn.assign(:flash, %{})
      |> MrEricWeb.PageController.call(MrEricWeb.PageController.init(:home))
    
    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
  end
end
