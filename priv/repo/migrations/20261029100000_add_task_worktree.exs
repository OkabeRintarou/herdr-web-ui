defmodule HerdrLiveView.Repo.Migrations.AddTaskWorktree do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :branch, :string
      add :worktree, :string
    end
  end
end
