defmodule HerdrLiveView.Teams.TeamWorkflow do
  @moduledoc "A workflow template a team can start tasks with; `definition` is the JSON form."
  use Ecto.Schema
  import Ecto.Changeset

  alias HerdrLiveView.Tasks.Workflow

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "team_workflows" do
    field(:key, :string)
    field(:name, :string)
    field(:definition, :map)
    belongs_to(:team, HerdrLiveView.Teams.Team, type: :string)

    timestamps()
  end

  def changeset(team_workflow, attrs) do
    team_workflow
    |> cast(attrs, [:id, :team_id, :key, :name, :definition])
    |> validate_required([:id, :team_id, :key, :name, :definition])
    |> unique_constraint([:team_id, :key], message: "Team 内已有同名流程")
  end

  @doc "The runnable workflow, stamped so tasks know which template they came from."
  def workflow(%__MODULE__{} = tw) do
    tw.definition
    |> Workflow.decode()
    |> Map.merge(%{id: tw.key, name: tw.name, source: :template})
    |> Map.put_new(:version, 1)
  end
end
