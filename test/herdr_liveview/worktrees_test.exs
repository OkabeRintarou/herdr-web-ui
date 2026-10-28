defmodule HerdrLiveView.WorktreesTest do
  use ExUnit.Case, async: true

  import HerdrLiveView.Fixtures, only: [git!: 2, init_repo!: 1]

  alias HerdrLiveView.Worktrees

  setup do
    %{tmp_dir: HerdrLiveView.Fixtures.scratch_dir!()}
  end

  defp project(dir), do: %{path: dir, default_branch: "main"}
  defp task(id), do: %{id: id, workdir: "", worktree: nil, branch: nil}

  test "a git project gets a worktree per task on its own branch", %{tmp_dir: dir} do
    init_repo!(dir)

    assert {:ok, task} = Worktrees.ensure(project(dir), task("t-a"))
    assert task.worktree == Path.join([dir, ".herdr-worktrees", "t-a"])
    assert task.workdir == task.worktree
    assert task.branch == "herdr/t-a"
    assert File.read!(Path.join(task.worktree, "README")) == "hi\n"
    assert git!(task.worktree, ["branch", "--show-current"]) == "herdr/t-a\n"

    # already there: nothing to do
    assert {:ok, ^task} = Worktrees.ensure(project(dir), task)

    # the main checkout stays clean
    assert git!(dir, ["status", "--porcelain"]) == ""
  end

  test "removing keeps the branch, and the worktree can be recreated from it", %{tmp_dir: dir} do
    init_repo!(dir)
    {:ok, task} = Worktrees.ensure(project(dir), task("t-b"))
    File.write!(Path.join(task.worktree, "work.txt"), "done\n")
    git!(task.worktree, ["add", "."])
    git!(task.worktree, ["commit", "-q", "-m", "work"])

    assert {:ok, removed} = Worktrees.remove(project(dir), task)
    assert removed.worktree == nil
    refute File.exists?(task.worktree)
    assert git!(dir, ["branch", "--list", "herdr/t-b"]) =~ "herdr/t-b"

    assert {:ok, again} = Worktrees.ensure(project(dir), removed)
    assert File.read!(Path.join(again.worktree, "work.txt")) == "done\n"
  end

  test "non-git folders are worked on in place", %{tmp_dir: dir} do
    task = %{task("t-c") | workdir: dir}
    assert {:ok, ^task} = Worktrees.ensure(project(dir), task)
  end

  test "a project in a subfolder of its repo works in that subfolder", %{tmp_dir: dir} do
    init_repo!(dir)
    File.mkdir_p!(Path.join(dir, "svc"))
    File.write!(Path.join([dir, "svc", "app"]), "x\n")
    git!(dir, ["add", "."])
    git!(dir, ["commit", "-q", "-m", "svc"])

    assert {:ok, task} = Worktrees.ensure(project(Path.join(dir, "svc")), task("t-e"))
    assert task.worktree == Path.join([dir, "svc", ".herdr-worktrees", "t-e"])
    assert task.workdir == Path.join(task.worktree, "svc")
    assert File.exists?(Path.join(task.workdir, "app"))
  end

  test "a repo without commits reports why", %{tmp_dir: dir} do
    git!(dir, ["init", "-q"])
    assert {:error, message} = Worktrees.ensure(project(dir), task("t-d"))
    assert message =~ "git worktree add"
  end
end
