defmodule MrEricWeb.PageController do
  use MrEricWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
