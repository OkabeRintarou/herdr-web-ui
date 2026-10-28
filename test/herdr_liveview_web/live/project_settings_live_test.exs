defmodule HerdrLiveViewWeb.ProjectSettingsLiveTest do
  use HerdrLiveViewWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import HerdrLiveView.Fixtures

  alias HerdrLiveView.Teams

  setup do
    %{project: project_fixture(%{slug: "demo"})}
  end

  test "lists the default team and its members", %{conn: conn, project: project} do
    team = Teams.default_team(project.id)
    {:ok, view, _html} = live(conn, ~p"/p/demo/settings")

    assert has_element?(view, "#teams-#{team.id}", "默认")

    for member <- team.members do
      assert has_element?(view, "#member-#{member.id}", member.name)
    end

    refute has_element?(view, "#delete-team-#{team.id}")
  end

  test "creates a blank team with its own roles, makes it default", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _html} = live(conn, ~p"/p/demo/settings")

    view |> element("#new-team") |> render_click()

    view
    |> form("#settings-form", team: %{name: "金融分析", max_concurrent_tasks: 0})
    |> render_change()

    assert has_element?(view, "#settings-form", "must be greater than 0")

    view
    |> form("#settings-form", team: %{preset: "blank", name: "金融分析", max_concurrent_tasks: 3})
    |> render_submit()

    team = Enum.find(Teams.list_teams(project.id), &(&1.name == "金融分析"))
    assert team.max_concurrent_tasks == 3
    assert has_element?(view, "#teams-#{team.id}", "还没有模板")

    view |> element("#new-member-#{team.id}") |> render_click()

    view
    |> form("#settings-form",
      member: %{
        name: "ana",
        role: "analyst",
        duty: "读财报，给出估值",
        agent_kind: "claude",
        agent_args: "--model opus",
        lifetime: "ephemeral"
      }
    )
    |> render_submit()

    assert [
             %{role: "lead"},
             %{name: "ana", role: "analyst", duty: "读财报，给出估值", lifetime: "ephemeral"}
           ] = Teams.get_team(team.id).members

    assert has_element?(view, "#teams-#{team.id}", "读财报，给出估值")

    view |> element("#set-default-#{team.id}") |> render_click()
    assert Teams.default_team(project.id).id == team.id
  end

  test "a software team lists its workflows; the last lead can't be deleted", %{
    conn: conn,
    project: project
  } do
    team = Teams.default_team(project.id)
    lead = Enum.find(team.members, &(&1.role == "lead"))
    [standard, quick] = team.workflows
    {:ok, view, _html} = live(conn, ~p"/p/demo/settings")

    assert has_element?(view, "#workflow-#{standard.id}", "规划（architect）")

    view |> element("#delete-workflow-#{quick.id}") |> render_click()
    refute has_element?(view, "#workflow-#{quick.id}")

    view |> element("#delete-member-#{lead.id}") |> render_click()
    assert has_element?(view, "#member-#{lead.id}")
    assert render(view) =~ "Team 至少要保留一个 lead"
  end

  test "edits and deletes members", %{conn: conn, project: project} do
    team = Teams.default_team(project.id)
    member = Enum.find(team.members, &(&1.role == "tester"))
    {:ok, view, _html} = live(conn, ~p"/p/demo/settings")

    view |> element("#member-#{member.id} button", "编辑") |> render_click()
    view |> form("#settings-form", member: %{notes: "只跑单测"}) |> render_submit()
    assert has_element?(view, "#member-#{member.id}", "只跑单测")

    view |> element("#delete-member-#{member.id}") |> render_click()
    refute has_element?(view, "#member-#{member.id}")

    assert Teams.missing_roles(Teams.get_team(team.id), %{steps: [%{role: "tester"}]}) == [
             "tester"
           ]
  end

  test "unknown projects go back to the overview", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/p/nope/settings")
  end
end
