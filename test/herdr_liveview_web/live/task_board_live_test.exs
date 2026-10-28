defmodule HerdrLiveViewWeb.TaskBoardLiveTest do
  use HerdrLiveViewWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import HerdrLiveView.Fixtures

  alias HerdrLiveView.{Tasks, Teams}
  alias HerdrLiveView.Tasks.Workflow

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    project = project_fixture(%{slug: "demo", path: dir})
    Tasks.seed_demo!(project)
    %{project: project}
  end

  test "changes are persisted and survive a reload", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/p/demo/tasks/t-102")
    view |> element("#task-start") |> render_click()

    {:ok, view, _html} = live(conn, ~p"/p/demo")
    assert has_element?(view, "#col-implement-cards #task-t-102")
  end

  test "renders phase columns with demo tasks", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/p/demo")

    for stage <- ~w(todo plan implement attention done) do
      assert has_element?(view, "#col-#{stage}")
    end

    assert has_element?(view, "#col-plan-cards #task-t-111", "代码评审 → 重新规划")
    assert has_element?(view, "#col-implement-cards #task-t-104", "第 2 轮")
    assert has_element?(view, "#col-attention-cards #task-t-110")
  end

  test "only this project's tasks are on its board", %{conn: conn} do
    other = project_fixture(%{slug: "other"})
    {:ok, _} = Tasks.create_task(%{"title" => "别的项目", "project_id" => other.id})

    {:ok, view, _html} = live(conn, ~p"/p/demo")
    refute render(view) =~ "别的项目"

    {:ok, view, _html} = live(conn, ~p"/p/other")
    assert has_element?(view, "#col-todo-cards", "别的项目")
    refute has_element?(view, "#task-t-101")
  end

  test "the drawer draws the workflow and highlights the current step", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/p/demo")

    view |> element("#task-t-104") |> render_click()

    assert_patch(view, ~p"/p/demo/tasks/t-104")
    assert has_element?(view, "#workflow-graph-node-code_review[data-state=current]")
    assert has_element?(view, "#workflow-graph-node-plan[data-state=visited]")
    assert has_element?(view, "#workflow-graph-edge-code_review-changes_requested", "1/3")
  end

  test "simulated verdicts move the task along the graph", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/p/demo/tasks/t-104")

    view |> element("#simulate-needs_replan") |> render_click()

    assert has_element?(view, "#col-plan-cards #task-t-104")
    assert has_element?(view, "#workflow-graph-node-plan[data-state=current]")
  end

  test "a lead-designed task goes through proposal, redesign and approval", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/p/demo/tasks/t-101")

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
    {:ok, view, _html} = live(conn, ~p"/p/demo/tasks/t-108")

    assert has_element?(view, "#decision-bar", "已达 2 次上限")
    view |> element("#extend") |> render_click()

    assert has_element?(view, "#col-implement-cards #task-t-108")
    assert has_element?(view, "#workflow-graph-node-fix[data-state=current]")
  end

  test "human acceptance can send work back", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/p/demo/tasks/t-112")

    view |> form("#send-back-form", comment: %{text: "漏了一个 flag"}) |> render_submit()

    assert has_element?(view, "#col-implement-cards #task-t-112")
    assert has_element?(view, "#task-timeline li", "漏了一个 flag")
  end

  test "creating a task validates the title and works in the project folder", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _html} = live(conn, ~p"/p/demo/new")

    view |> form("#new-task-form", task: %{title: " "}) |> render_submit()
    assert has_element?(view, "#new-task-form", "标题不能为空")

    view
    |> form("#new-task-form", task: %{title: "写看板测试", workflow: "quick", executor: "simulated"})
    |> render_submit()

    assert has_element?(view, "#col-todo-cards", "写看板测试")

    assert [%{workdir: workdir, project_id: project_id}] =
             Enum.filter(Tasks.list_tasks(project.id), &(&1.title == "写看板测试"))

    assert {workdir, project_id} == {project.path, project.id}
  end

  test "herdr-executed tasks need a template workflow", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/p/demo/new")

    view
    |> form("#new-task-form", task: %{title: "真跑", executor: "herdr", workflow: "lead"})
    |> render_submit()

    assert has_element?(view, "#new-task-form", "真实执行暂只支持模板流程")

    view
    |> form("#new-task-form", task: %{title: "真跑", executor: "herdr", workflow: "quick"})
    |> render_submit()

    assert has_element?(view, "#col-todo-cards", "真跑")
    assert [%{executor: "herdr"}] = Enum.filter(Tasks.list_tasks(), &(&1.title == "真跑"))
  end

  test "a task's team must have every role its workflow needs", %{conn: conn, project: project} do
    {:ok, team} = Teams.create_team(project.id, %{"name" => "单人队"})

    {:ok, _} =
      Teams.create_member(team.id, %{
        "name" => "solo",
        "role" => "coder",
        "agent_kind" => "copilot"
      })

    {:ok, view, _html} = live(conn, ~p"/p/demo/new")
    attrs = %{title: "小改动", executor: "simulated", workflow: "quick", team_id: team.id}

    view |> form("#new-task-form", task: attrs) |> render_submit()
    assert has_element?(view, "#new-task-form", "单人队 没有这个流程")

    {:ok, _} = Teams.save_workflow(team.id, Workflow.quick())
    {:ok, view, _html} = live(conn, ~p"/p/demo/new")
    view |> form("#new-task-form", task: attrs) |> render_submit()
    assert has_element?(view, "#new-task-form", "单人队 里没有这个流程需要的角色：reviewer")

    {:ok, _} =
      Teams.create_member(team.id, %{
        "name" => "rev",
        "role" => "reviewer",
        "agent_kind" => "claude"
      })

    {:ok, view, _html} = live(conn, ~p"/p/demo/new")
    view |> form("#new-task-form", task: attrs) |> render_submit()

    assert has_element?(view, "#col-todo-cards", "单人队")
    assert [%{team_id: team_id}] = Enum.filter(Tasks.list_tasks(), &(&1.title == "小改动"))
    assert team_id == team.id
  end

  test "starting a real task queues it for its team", %{conn: conn, project: project} do
    team = Teams.default_team(project.id)

    {:ok, task} =
      Tasks.create_task(%{
        "title" => "排队",
        "project_id" => project.id,
        "workflow" => "quick",
        "executor" => "herdr",
        "team_id" => team.id
      })

    {:ok, view, _html} = live(conn, ~p"/p/demo/tasks/#{task.id}")
    view |> element("#task-start") |> render_click()

    assert has_element?(view, "#task-#{task.id}", "排队中")
    assert %{queued: true, stage: :todo} = Tasks.get_task(task.id)
  end

  test "the board links to the project's settings", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/p/demo")

    assert {:error, {:live_redirect, %{to: "/p/demo/settings"}}} =
             view |> element("#project-settings") |> render_click()
  end

  test "unknown task ids fall back to the board", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/p/demo"}}} = live(conn, ~p"/p/demo/tasks/nope")
  end

  test "unknown projects go back to the overview", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/p/nope")
  end
end
