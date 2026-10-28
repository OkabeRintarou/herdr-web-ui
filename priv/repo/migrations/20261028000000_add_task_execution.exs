defmodule HerdrLiveView.Repo.Migrations.AddTaskExecution do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :executor, :string, null: false, default: "simulated"
      add :workspace_id, :string
      add :agents, :map, null: false, default: %{}
    end
  end
end
