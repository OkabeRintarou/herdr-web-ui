defmodule HerdrLiveView.TeamsTest do
  use HerdrLiveView.DataCase, async: false

  import HerdrLiveView.Fixtures

  alias HerdrLiveView.{Tasks, Teams}
  alias HerdrLiveView.Tasks.{Runner, Workflow}
  alias HerdrLiveView.Teams.Scheduler

  setup do
    %{project: project_fixture()}
  end

  test "every project gets a software team with its roles and workflows", %{project: project} do
    team = Teams.default_team(project.id)

    assert team.is_default
    assert Enum.sort(Teams.roles(team)) == ~w(architect coder lead reviewer tester)
    assert Enum.all?(team.members, &(&1.duty != ""))
    assert [%{id: "standard"} = standard, %{id: "quick"}] = Teams.workflows(team)
    assert Teams.missing_roles(team, standard) == []
    assert Workflow.step(standard, "plan").instructions =~ "{dir}/plan.md"
  end

  test "a blank team defines its own roles", %{project: project} do
    {:ok, team} = Teams.create_team(project.id, %{"name" => "金融分析"}, "blank")
    assert Teams.roles(team) == ["lead"]
    assert Teams.workflows(team) == []

    {:ok, _} =
      Teams.create_member(team.id, %{
        "name" => "ana",
        "role" => "analyst",
        "duty" => "读财报，给出估值",
        "agent_kind" => "claude"
      })

    workflow = %{steps: [%{role: "analyst"}, %{role: "risk-reviewer"}, %{role: "human"}]}
    assert Teams.missing_roles(Teams.get_team(team.id), workflow) == ["risk-reviewer"]
  end

  test "a team always keeps a lead", %{project: project} do
    {:ok, team} = Teams.create_team(project.id, %{"name" => "小队"}, "blank")
    [lead] = team.members

    assert {:error, :last_lead} = Teams.delete_member(lead)
    assert {:error, changeset} = Teams.update_member(lead, %{"role" => "analyst"})
    assert %{role: ["Team 至少要保留一个 lead"]} = errors_on(changeset)

    {:ok, _} =
      Teams.create_member(team.id, %{"name" => "lead2", "role" => "lead", "agent_kind" => "codex"})

    assert {:ok, _} = Teams.delete_member(lead)
  end

  test "the first team stays default; only non-default teams can be deleted", %{project: project} do
    default = Teams.default_team(project.id)
    {:ok, other} = Teams.create_team(project.id, %{"name" => "\u7b2c\u4e8c\u961f"})
    refute other.is_default

    assert {:error, :default_team} = Teams.delete_team(default)

    {:ok, _} = Teams.set_default(other)
    assert Teams.default_team(project.id).id == other.id
    assert {:ok, _} = default |> then(&Teams.get_team(&1.id)) |> Teams.delete_team()
  end

  test "members are validated", %{project: project} do
    team = Teams.default_team(project.id)

    assert {:error, changeset} =
             Teams.create_member(team.id, %{
               "name" => "Coder",
               "role" => "human",
               "agent_kind" => "copilot"
             })

    assert %{name: [_], role: [_]} = errors_on(changeset)

    assert {:error, changeset} =
             Teams.create_member(team.id, %{
               "name" => "x",
               "role" => "Bad Role",
               "agent_kind" => "copilot"
             })

    assert %{role: [_]} = errors_on(changeset)

    assert {:error, changeset} =
             Teams.create_member(team.id, %{
               "name" => "coder",
               "role" => "coder",
               "agent_kind" => "copilot"
             })

    assert %{team_id: ["Team \u5185\u5df2\u6709\u540c\u540d\u6210\u5458"]} = errors_on(changeset)

    assert {:error, changeset} =
             Teams.create_member(team.id, %{
               "name" => "c2",
               "role" => "coder",
               "agent_kind" => "copilot",
               "agent_args" => "--x 'oops"
             })

    assert %{agent_args: ["\u5f15\u53f7\u4e0d\u5339\u914d"]} = errors_on(changeset)
  end

  test "updates cannot move a member to another team", %{project: project} do
    team = Teams.default_team(project.id)
    {:ok, other} = Teams.create_team(project.id, %{"name" => "\u522b\u961f"})
    [member | _] = team.members

    {:ok, member} =
      Teams.update_member(member, %{"team_id" => other.id, "notes" => "\u6539\u4e86"})

    assert {member.team_id, member.notes} == {team.id, "\u6539\u4e86"}
  end

  describe "scheduler" do
    defp queued_task(project, team, title) do
      {:ok, task} =
        %{
          "title" => title,
          "project_id" => project.id,
          "workflow" => "quick",
          "executor" => "herdr",
          "team_id" => team.id
        }
        |> Runner.new()
        |> Runner.enqueue()
        |> Tasks.save_task()

      task
    end

    test "starts queued tasks up to the team's limit, then the next when one finishes", %{
      project: project
    } do
      {:ok, team} =
        project.id |> Teams.default_team() |> Teams.update_team(%{"max_concurrent_tasks" => 2})

      [a, b, c] = for t <- ~w(a b c), do: queued_task(project, team, t)

      :ok = Scheduler.drain(team.id)

      assert [false, false, true] = Enum.map([a, b, c], &Tasks.get_task(&1.id).queued)
      assert Scheduler.active_count(team.id) == 2

      {:ok, _} = Tasks.save_task(Runner.cancel(Tasks.get_task(a.id), DateTime.utc_now()))
      :ok = Scheduler.drain(team.id)

      assert %{queued: false, stage: :implement} = Tasks.get_task(c.id)
    end

    test "teams don't share slots", %{project: project} do
      {:ok, team} =
        project.id |> Teams.default_team() |> Teams.update_team(%{"max_concurrent_tasks" => 1})

      {:ok, other} =
        Teams.create_team(project.id, %{
          "name" => "\u53e6\u4e00\u961f",
          "max_concurrent_tasks" => 1
        })

      a = queued_task(project, team, "a")
      b = queued_task(project, other, "b")
      Scheduler.drain_all()

      refute Tasks.get_task(a.id).queued
      refute Tasks.get_task(b.id).queued
    end
  end
end
