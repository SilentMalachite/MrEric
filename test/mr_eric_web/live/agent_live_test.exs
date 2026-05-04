defmodule MrEricWeb.AgentLiveTest do
  use MrEricWeb.ConnCase
  import Phoenix.LiveViewTest

  test "renders agent interface", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert html =~ "MrEric AI Agent"
    assert html =~ "Provider"
    assert html =~ "Model"
    assert has_element?(view, "#task-form")
    assert has_element?(view, "#provider-select")
    assert has_element?(view, "#model-select")
  end

  test "displays provider and model selection dropdowns", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, "select[name='provider']")
    assert has_element?(view, "option[value='openai']")
    assert has_element?(view, "option[value='ollama']")
    assert has_element?(view, "option[value='lmstudio']")

    assert has_element?(view, "#model-select")
    assert has_element?(view, "option[value='gpt-4o']")
    refute has_element?(view, "option[value='llama3.1']")
  end

  test "changes provider selection and refreshes models", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("#provider-select")
    |> render_change(%{"provider" => "ollama"})

    assert has_element?(view, "option[value='llama3.1']")
    assert render(view) =~ "ollama"
    assert render(view) =~ "llama3.1"
  end

  test "changes model selection", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("#model-select")
    |> render_change(%{"model" => "gpt-4o-mini"})

    html = render(view)
    assert html =~ "gpt-4o-mini"
  end

  test "passes selected provider and model to execution and streaming", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("#provider-select")
    |> render_change(%{"provider" => "ollama"})

    view
    |> element("#model-select")
    |> render_change(%{"model" => "llama3.1"})

    view
    |> form("#task-form", %{"task" => "report provider"})
    |> render_submit()

    Process.sleep(100)

    html = render(view)
    assert html =~ "provider:ollama model:llama3.1"
    assert html =~ "Plan"
    assert html =~ "Drafts"
    assert html =~ "Review"
    assert html =~ "Final"
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

  test "renders a recoverable error when the selected LLM is unavailable", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    send(view.pid, {:agent_error, :econnrefused})

    html = render(view)
    assert html =~ "The selected LLM provider is unavailable"
    assert has_element?(view, "#task-form")
  end
end
