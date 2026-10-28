defmodule HerdrLiveViewWeb.ProjectsLiveTest do
  use HerdrLiveViewWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import HerdrLiveView.Fixtures

  alias HerdrLiveView.{Projects, Tasks}
  alias HerdrLiveView.Tasks.Runner

  @moduletag :tmp_dir

  test "lists projects with per-stage counts and a cross-project attention inbox", %{
    conn: conn
  } do
    a = project_fixture(%{name: "Alpha", slug: "alpha"})
    b = project_fixture(%{name: "Beta", slug: "beta"})

    {:ok, _} = Tasks.create_task(%{"title" => "a1", "project_id" => a.id})

    blocked =
      Runner.new(%{"title" => "卡住了", "project_id" => b.id, "workflow" => "quick"})
      |> Runner.start(DateTime.utc_now())
      |> Runner.block("需要审批")

    {:ok, _} = Tasks.save_task(blocked)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#projects a[href='/p/alpha']", "待办 1")
    assert has_element?(view, "#projects a[href='/p/beta']", "待人处理 1")
    assert has_element?(view, "#attention a[href='/p/beta/tasks/#{blocked.id}']", "需要审批")
  end

  test "the overview follows task changes live", %{conn: conn} do
    project = project_fixture(%{slug: "live"})
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#attention-empty")

    task =
      Runner.new(%{"title" => "新问题", "project_id" => project.id, "workflow" => "quick"})
      |> Runner.start(DateTime.utc_now())
      |> Runner.block("出错了")

    {:ok, _} = Tasks.save_task(task)
    assert has_element?(view, "#attention", "新问题")
  end

  test "creates a project, deriving the slug and checking the folder", %{
    conn: conn,
    tmp_dir: dir
  } do
    host = host_fixture(%{"name" => "box"})
    {:ok, view, _html} = live(conn, ~p"/projects/new")

    view
    |> form("#new-project-form",
      project: %{name: "My App", host_id: host.id, path: Path.join(dir, "missing")}
    )
    |> render_change()

    assert has_element?(view, "#new-project-form input[name='project[slug]'][value='my-app']")
    assert has_element?(view, "#new-project-form", "目录不存在")

    view
    |> form("#new-project-form", project: %{name: "My App", host_id: host.id, path: dir})
    |> render_submit()

    assert_redirect(view, ~p"/p/my-app")
    assert %{path: ^dir, host_id: host_id} = Projects.get_by_slug("my-app")
    assert host_id == host.id
  end
end
