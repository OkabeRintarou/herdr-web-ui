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

  test "adds an ssh host and checks its connection", %{conn: conn} do
    Application.put_env(
      :herdr_liveview,
      :ssh_command,
      Path.expand("../../support/fake_ssh", __DIR__)
    )

    on_exit(fn -> Application.delete_env(:herdr_liveview, :ssh_command) end)

    {:ok, view, _html} = live(conn, ~p"/hosts/new")

    view
    |> form("#new-host-form", host: %{name: "gpu", ssh_target: "-bad", remote_socket: "x"})
    |> render_change()

    assert has_element?(view, "#new-host-form", "只能是 user@host")

    view
    |> form("#new-host-form",
      host: %{name: "gpu", ssh_target: "me@gpu", remote_socket: "/nowhere/herdr.sock"}
    )
    |> render_submit()

    assert_patch(view, ~p"/")
    host = Enum.find(HerdrLiveView.Hosts.list_hosts(), &(&1.name == "gpu"))
    assert has_element?(view, "#host-#{host.id}", "ssh me@gpu")

    render_async(view)
    assert has_element?(view, "#host-checks-#{host.id}", "✓ ssh 连接 me@gpu")
    assert has_element?(view, "#host-checks-#{host.id}", "/nowhere/herdr.sock 不存在")
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
