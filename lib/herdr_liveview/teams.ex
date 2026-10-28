defmodule HerdrLiveView.Teams do
  @moduledoc "Teams and member templates of a project."
  import Ecto.Query

  alias HerdrLiveView.Repo
  alias HerdrLiveView.Tasks.Workflow
  alias HerdrLiveView.Teams.{Member, Team, TeamWorkflow}

  @preloads [:members, :workflows]

  @lead_duty "理解需求，为 task 设计流程并挑选成员；遇到分歧时做取舍。"

  @presets %{
    "software" => %{
      label: "软件开发（5 个角色 + 标准、快速流程）",
      members: [
        {"lead", @lead_duty},
        {"architect", "阅读代码，写实施方案并评估风险。"},
        {"coder", "按方案实现并提交 commit，修复评审提出的问题。"},
        {"reviewer", "评审方案和代码改动，逐条指出问题。"},
        {"tester", "补充并运行测试，报告结果。"}
      ],
      workflows: :software
    },
    "blank" => %{
      label: "空白（只有 lead）",
      members: [{"lead", @lead_duty}],
      workflows: :none
    }
  }

  def presets, do: [{@presets["software"].label, "software"}, {@presets["blank"].label, "blank"}]

  def list_teams(project_id) do
    from(t in Team,
      where: t.project_id == ^project_id,
      order_by: [desc: t.is_default, asc: t.inserted_at],
      preload: ^@preloads
    )
    |> Repo.all()
  end

  def get_team(nil), do: nil
  def get_team(id), do: Team |> Repo.get(id) |> Repo.preload(@preloads)

  def default_team(project_id) do
    from(t in Team, where: t.project_id == ^project_id and t.is_default, preload: ^@preloads)
    |> Repo.one()
  end

  def change_team(team \\ %Team{}, attrs \\ %{}), do: Team.changeset(team, attrs)
  def change_member(member \\ %Member{}, attrs \\ %{}), do: Member.changeset(member, attrs)

  @doc "Creates a team with the preset's members (using the configured agent CLI) and workflows."
  def create_team(project_id, attrs, preset \\ "blank") do
    first? = not Repo.exists?(from(t in Team, where: t.project_id == ^project_id))
    %{members: members, workflows: workflows} = Map.fetch!(@presets, preset)
    {kind, args} = configured_agent()

    Repo.transaction(fn ->
      team =
        %Team{is_default: first?}
        |> Team.changeset(
          attrs
          |> stringify()
          |> Map.merge(%{"id" => new_id("tm"), "project_id" => project_id})
        )
        |> Repo.insert()
        |> case do
          {:ok, team} -> team
          {:error, changeset} -> Repo.rollback(changeset)
        end

      for {role, duty} <- members do
        attrs = %{"name" => role, "role" => role, "duty" => duty, "agent_kind" => kind}
        {:ok, _} = create_member(team.id, Map.put(attrs, "agent_args", args))
      end

      for workflow <- preset_workflows(workflows), do: {:ok, _} = save_workflow(team.id, workflow)

      team
    end)
    |> preload()
  end

  defp preset_workflows(:software), do: Workflow.templates()
  defp preset_workflows(:none), do: []

  def update_team(team, attrs) do
    team
    |> Team.changeset(attrs |> stringify() |> Map.drop(["id", "project_id"]))
    |> Repo.update()
    |> preload()
  end

  def set_default(%Team{} = team) do
    Repo.transaction(fn ->
      from(t in Team, where: t.project_id == ^team.project_id)
      |> Repo.update_all(set: [is_default: false])

      team |> Ecto.Changeset.change(is_default: true) |> Repo.update!()
    end)
  end

  def delete_team(%Team{is_default: true}), do: {:error, :default_team}
  def delete_team(%Team{} = team), do: Repo.delete(team)

  def create_member(team_id, attrs) do
    %Member{}
    |> Member.changeset(
      attrs
      |> stringify()
      |> Map.merge(%{"id" => new_id("m"), "team_id" => team_id})
    )
    |> Repo.insert()
  end

  def update_member(member, attrs) do
    member
    |> Member.changeset(attrs |> stringify() |> Map.drop(["id", "team_id"]))
    |> keep_a_lead(member)
    |> Repo.update()
  end

  def delete_member(member) do
    if last_lead?(member), do: {:error, :last_lead}, else: Repo.delete(member)
  end

  def get_member!(id), do: Repo.get!(Member, id)

  defp keep_a_lead(changeset, member) do
    if Ecto.Changeset.get_field(changeset, :role) != "lead" and last_lead?(member),
      do: Ecto.Changeset.add_error(changeset, :role, "Team 至少要保留一个 lead"),
      else: changeset
  end

  defp last_lead?(%Member{role: "lead", team_id: team_id}) do
    from(m in Member, where: m.team_id == ^team_id and m.role == "lead")
    |> Repo.aggregate(:count) == 1
  end

  defp last_lead?(_member), do: false

  def save_workflow(team_id, workflow) do
    %TeamWorkflow{}
    |> TeamWorkflow.changeset(%{
      id: new_id("wf"),
      team_id: team_id,
      key: workflow.id,
      name: workflow.name,
      definition: Workflow.encode(workflow)
    })
    |> Repo.insert()
  end

  def delete_workflow(%TeamWorkflow{} = tw), do: Repo.delete(tw)

  @doc "The team's template `key` as a runnable workflow, or nil."
  def workflow(%Team{workflows: workflows}, key) do
    with %TeamWorkflow{} = tw <- Enum.find(workflows, &(&1.key == key)),
         do: TeamWorkflow.workflow(tw)
  end

  def workflow(_team, _key), do: nil

  def workflows(%Team{workflows: workflows}), do: Enum.map(workflows, &TeamWorkflow.workflow/1)
  def workflows(_team), do: []

  @doc "The member that plays `role` in this team (first one added, until a Leader picks)."
  def member_for(%Team{members: members}, role), do: Enum.find(members, &(&1.role == role))
  def member_for(_team, _role), do: nil

  def roles(%Team{members: members}), do: members |> Enum.map(& &1.role) |> Enum.uniq()

  @doc "Roles a workflow needs that this team has nobody for (the human step needs no member)."
  def missing_roles(%Team{} = team, %{steps: steps}) do
    needed = steps |> Enum.map(& &1.role) |> Enum.reject(&(&1 == "human")) |> Enum.uniq()
    needed -- roles(team)
  end

  def missing_roles(_team, _workflow), do: []

  @doc "Every project gets a team to start from, built from the configured agent CLI."
  def ensure_default_team!(project_id) do
    case list_teams(project_id) do
      [] ->
        {:ok, team} = create_team(project_id, %{"name" => "默认队"}, "software")
        team

      [team | _] ->
        team
    end
  end

  def configured_agent do
    kind = Application.get_env(:herdr_liveview, :agent_kind, "copilot")
    args = Application.get_env(:herdr_liveview, :agent_args, [])

    {if(kind in Member.kinds(), do: kind, else: "copilot"),
     Enum.map_join(args, " ", &shell_quote/1)}
  end

  defp shell_quote(arg), do: if(String.match?(arg, ~r/[\s'"]/), do: "'#{arg}'", else: arg)

  defp preload({:ok, team}), do: {:ok, Repo.preload(team, @preloads, force: true)}
  defp preload(error), do: error

  defp new_id(prefix),
    do: "#{prefix}-" <> Base.encode32(:crypto.strong_rand_bytes(4), case: :lower, padding: false)

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end
