defmodule HerdrLiveViewWeb.TaskBoardLiveTest do
  use HerdrLiveViewWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    HerdrLiveView.Tasks.seed_demo!()
  end

  test "changes are persisted and survive a reload", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tasks/t-102")
    view |> element("#task-start") |> render_click()

    {:ok, view, _html} = live(conn, ~p"/tasks")
    assert has_element?(view, "#col-implement-cards #task-t-102")
  end

  test "renders phase columns with demo tasks", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tasks")

    for stage <- ~w(todo plan implement attention done) do
      assert has_element?(view, "#col-#{stage}")
    end

    assert has_element?(view, "#col-plan-cards #task-t-111", "代码评审 → 重新规划")
    assert has_element?(view, "#col-implement-cards #task-t-104", "第 2 轮")
    assert has_element?(view, "#col-attention-cards #task-t-110")
  end

  test "the drawer draws the workflow and highlights the current step", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tasks")

    view |> element("#task-t-104") |> render_click()

    assert_patch(view, ~p"/tasks/t-104")
    assert has_element?(view, "#workflow-graph-node-code_review[data-state=current]")
    assert has_element?(view, "#workflow-graph-node-plan[data-state=visited]")
    assert has_element?(view, "#workflow-graph-edge-code_review-changes_requested", "1/3")
  end

  test "simulated verdicts move the task along the graph", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tasks/t-104")

    view |> element("#simulate-needs_replan") |> render_click()

    assert has_element?(view, "#col-plan-cards #task-t-104")
    assert has_element?(view, "#workflow-graph-node-plan[data-state=current]")
  end

  test "a lead-designed task goes through proposal, redesign and approval", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tasks/t-101")

    view |> element("#task-start") |> render_click()
    assert has_element?(view, "#col-plan-cards #task-t-101", "设计流程")

    send(view.pid, {:lead_proposal, "t-101", 1, nil})
    assert has_element?(view, "#col-attention-cards #task-t-101")
    assert has_element?(view, "#proposal-graph-node-test")
    assert has_element?(view, "#workflow-checks li", "能到达完成")

    view |> form("#redesign-form", comment: %{text: "不需要单独测试"}) |> render_submit()
    send(view.pid, {:lead_proposal, "t-101", 2, "不需要单独测试"})
    assert has_element?(view, "#workflow-diff", "规划评审")
    refute has_element?(view, "#proposal-graph-node-test")

    view |> element("#approve-workflow") |> render_click()
    assert has_element?(view, "#col-plan-cards #task-t-101", "lead 设计 v2")
    assert has_element?(view, "#workflow-graph-node-plan[data-state=current]")
  end

  test "a capped loop waits for a human, who can release one more round", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tasks/t-108")

    assert has_element?(view, "#decision-bar", "已达 2 次上限")
    view |> element("#extend") |> render_click()

    assert has_element?(view, "#col-implement-cards #task-t-108")
    assert has_element?(view, "#workflow-graph-node-fix[data-state=current]")
  end

  test "human acceptance can send work back", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tasks/t-112")

    view |> form("#send-back-form", comment: %{text: "漏了一个 flag"}) |> render_submit()

    assert has_element?(view, "#col-implement-cards #task-t-112")
    assert has_element?(view, "#task-timeline li", "漏了一个 flag")
  end

  test "creating a task validates the title", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tasks/new")

    view |> form("#new-task-form", task: %{title: " "}) |> render_submit()
    assert has_element?(view, "#new-task-form", "标题不能为空")

    view |> form("#new-task-form", task: %{title: "写看板测试", workflow: "quick"}) |> render_submit()
    assert has_element?(view, "#col-todo-cards", "写看板测试")
  end

  test "unknown task ids fall back to the board", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/tasks"}}} = live(conn, ~p"/tasks/nope")
  end
end
