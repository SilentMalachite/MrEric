defmodule MrEricWeb.AgentLiveTest do
  use MrEricWeb.ConnCase
  import Phoenix.LiveViewTest

  test "renders agent interface", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert html =~ "MrEric AI Agent"
    assert html =~ "OpenAI Model"
    assert has_element?(view, "#task-form")
  end

  test "displays model selection dropdown", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, "select[name='model']")
    assert has_element?(view, "option[value='gpt-4o']")
    assert has_element?(view, "option[value='gpt-3.5-turbo']")
    assert has_element?(view, "option[value='gpt-4-turbo']")
  end

  test "changes model selection", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("select[name='model']")
    |> render_change(%{"model" => "gpt-3.5-turbo"})

    html = render(view)
    assert html =~ "gpt-3.5-turbo"
  end

  test "shows loading state when executing task", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> form("#task-form", %{"task" => "Test task"})
    |> render_submit()

    # Wait a moment for async task to start
    Process.sleep(50)

    # Should have response from streaming
    assert render(view) =~ "Mock response"
  end
end
