defmodule HerdrLiveView.Teams.Team do
  @moduledoc "A set of member templates (role → agent config) inside one project."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "teams" do
    field(:name, :string)
    field(:description, :string, default: "")
    field(:is_default, :boolean, default: false)
    field(:max_concurrent_tasks, :integer, default: 2)
    field(:step_timeout_min, :integer, default: 60)
    belongs_to(:project, HerdrLiveView.Projects.Project, type: :string)
    has_many(:members, HerdrLiveView.Teams.Member, preload_order: [asc: :inserted_at])
    has_many(:workflows, HerdrLiveView.Teams.TeamWorkflow, preload_order: [asc: :inserted_at])

    timestamps()
  end

  def changeset(team, attrs) do
    team
    |> cast(attrs, [
      :id,
      :project_id,
      :name,
      :description,
      :max_concurrent_tasks,
      :step_timeout_min
    ])
    |> validate_required([:id, :project_id, :name])
    |> validate_length(:name, max: 40)
    |> validate_number(:max_concurrent_tasks, greater_than: 0, less_than_or_equal_to: 20)
    |> validate_number(:step_timeout_min, greater_than: 0, less_than_or_equal_to: 24 * 60)
  end
end
