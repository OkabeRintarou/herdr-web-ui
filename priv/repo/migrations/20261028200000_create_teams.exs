defmodule HerdrLiveView.Repo.Migrations.CreateTeams do
  use Ecto.Migration

  def change do
    create table(:teams, primary_key: false) do
      add :id, :string, primary_key: true
      add :project_id, references(:projects, type: :string, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :description, :text, null: false, default: ""
      add :is_default, :boolean, null: false, default: false
      add :max_concurrent_tasks, :integer, null: false, default: 2
      add :step_timeout_min, :integer, null: false, default: 60
      timestamps(type: :utc_datetime_usec)
    end

    create index(:teams, [:project_id])

    create table(:team_members, primary_key: false) do
      add :id, :string, primary_key: true
      add :team_id, references(:teams, type: :string, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :role, :string, null: false
      add :agent_kind, :string, null: false
      add :agent_args, :text, null: false, default: ""
      add :duty, :text, null: false, default: ""
      add :notes, :text, null: false, default: ""
      add :lifetime, :string, null: false, default: "resident"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:team_members, [:team_id, :name])

    create table(:team_workflows, primary_key: false) do
      add :id, :string, primary_key: true
      add :team_id, references(:teams, type: :string, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :name, :string, null: false
      add :definition, :map, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:team_workflows, [:team_id, :key])

    alter table(:tasks) do
      add :team_id, references(:teams, type: :string, on_delete: :nilify_all)
      add :queued, :boolean, null: false, default: false
    end
  end
end
