defmodule HerdrLiveViewWeb.DashboardLiveTest do
  use HerdrLiveViewWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias HerdrLiveView.Herdr.Panes

  @panes %{
    "w1:p1" => %{
      "pane_id" => "w1:p1",
      "workspace_id" => "w1",
      "tab_id" => "w1:t1",
      "agent" => "codex",
      "label" => "reviewer",
      "agent_status" => "blocked",
      "cwd" => "/tmp"
    },
    "w1:p2" => %{
      "pane_id" => "w1:p2",
      "workspace_id" => "w1",
      "tab_id" => "w1:t1",
      "agent_status" => "unknown",
      "cwd" => "/tmp"
    }
  }

  defp broadcast(status, panes) do
    Phoenix.PubSub.broadcast(HerdrLiveView.PubSub, Panes.topic(), {:herdr_panes, status, panes})
  end

  test "shows the disconnected state with no agents", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#herdr-connection", "disconnected")
    refute has_element?(view, "#agents li[id^=agent-]")
  end

  test "lists only panes running an agent and follows updates", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    broadcast(:connected, @panes)

    assert has_element?(view, "#herdr-connection", "connected")
    assert has_element?(view, "#agent-w1-p1", "reviewer")
    assert has_element?(view, "#agent-w1-p1", "blocked")
    refute has_element?(view, "#agent-w1-p2")

    broadcast(:connected, put_in(@panes, ["w1:p1", "agent_status"], "working"))
    assert has_element?(view, "#agent-w1-p1", "working")

    broadcast(:connected, Map.delete(@panes, "w1:p1"))
    refute has_element?(view, "#agent-w1-p1")
  end

  test "selecting an agent shows the terminal and input controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    broadcast(:connected, @panes)

    view |> element("#agent-w1-p1 a") |> render_click()

    assert_patch(view, ~p"/panes/#{"w1:p1"}")
    assert has_element?(view, "#terminal[phx-hook=Terminal]")
    assert has_element?(view, "#prompt-form")
    assert has_element?(view, "#key-ctrl-c")
  end

  test "herdr failures are reported instead of crashing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/panes/w1:p1")

    view |> form("#prompt-form", prompt: %{text: "hello"}) |> render_submit()
    assert render(view) =~ "Prompt failed"

    view |> element("#key-esc") |> render_click()
    assert render(view) =~ "Key esc failed"
  end

  test "rejects keys outside the allow-list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/panes/w1:p1")

    render_hook(view, "key", %{"key" => "ctrl+z"})
    assert render(view) =~ "invalid_key"
  end
end
