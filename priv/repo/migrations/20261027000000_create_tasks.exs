defmodule HerdrLiveView.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  # Only types both SQLite and PostgreSQL support; nested state is stored as JSON maps/arrays.
  def change do
    create table(:tasks, primary_key: false) do
      add :id, :string, primary_key: true
      add :title, :string, null: false
      add :description, :text, null: false, default: ""
      add :priority, :string, null: false
      add :repo, :string, null: false, default: ""
      add :workflow_source, :string, null: false
      add :stage, :string, null: false
      add :step, :string
      add :paused, :boolean, null: false, default: false
      add :cancelled, :boolean, null: false, default: false
      add :pane_id, :string
      add :agent_status, :string
      add :stage_since, :utc_datetime_usec, null: false
      add :last_bounce, :string
      add :workflow, :map
      add :proposal, :map
      add :previous_workflow, :map
      add :visits, :map, null: false
      add :edge_counts, :map, null: false
      add :attention, :map
      add :timeline, {:array, :map}, null: false
      add :artifacts, {:array, :string}, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tasks, [:stage])
  end
end
