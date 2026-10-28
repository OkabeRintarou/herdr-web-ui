defmodule HerdrLiveView.Worktrees do
  @moduledoc """
  Each herdr-executed task in a git project works in its own worktree
  (`<project>/.herdr-worktrees/<task>` on branch `herdr/<task>`), so parallel tasks don't
  trample each other. Non-git folders are worked on in place.
  """

  @dir ".herdr-worktrees"
  @ignored [".herdr-worktrees/", ".herdr-tasks/"]

  def branch(task), do: "herdr/#{task.id}"
  def path(project, task), do: Path.join([project.path, @dir, task.id])

  @doc "Makes sure the task has its worktree; returns the task pointed at it."
  def ensure(project, task) do
    cond do
      task.worktree && File.dir?(task.worktree) -> {:ok, task}
      not git_repo?(project.path) -> {:ok, task}
      true -> create(project, task)
    end
  end

  @doc "Removes the worktree directory; the branch (and its commits) stays."
  def remove(project, %{worktree: dir} = task) when is_binary(dir) do
    with {:ok, _} <- git(project.path, ["worktree", "remove", "--force", dir]) do
      {:ok, %{task | worktree: nil}}
    end
  end

  def remove(_project, task), do: {:ok, task}

  def git_repo?(path) do
    File.dir?(path) and match?({:ok, "true"}, git(path, ["rev-parse", "--is-inside-work-tree"]))
  end

  defp create(project, task) do
    dir = path(project, task)
    branch = branch(task)

    args =
      if ref?(project.path, "refs/heads/#{branch}"),
        do: ["worktree", "add", dir, branch],
        else: ["worktree", "add", "-b", branch, dir, base(project)]

    with :ok <- ignore(project.path),
         {:ok, prefix} <- git(project.path, ["rev-parse", "--show-prefix"]),
         {:ok, _} <- git(project.path, ["worktree", "prune"]),
         {:ok, _} <- git(project.path, args) do
      # a project may be a subfolder of its repo; agents work in the same subfolder
      {:ok, %{task | workdir: Path.join(dir, prefix), worktree: dir, branch: branch}}
    end
  end

  defp base(project) do
    if ref?(project.path, "refs/heads/#{project.default_branch}"),
      do: project.default_branch,
      else: "HEAD"
  end

  defp ref?(path, ref), do: match?({:ok, _}, git(path, ["rev-parse", "--verify", "--quiet", ref]))

  # info/exclude rather than .gitignore: nothing to commit, and it covers every worktree.
  defp ignore(path) do
    with {:ok, common} <- git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) do
      file = Path.join([common, "info", "exclude"])
      current = if File.exists?(file), do: File.read!(file), else: ""
      missing = Enum.reject(@ignored, &(&1 in String.split(current, "\n")))

      if missing != [] do
        File.mkdir_p!(Path.dirname(file))
        prefix = if current == "" or String.ends_with?(current, "\n"), do: "", else: "\n"
        File.write!(file, prefix <> Enum.join(missing, "\n") <> "\n", [:append])
      end

      :ok
    end
  end

  defp git(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, "git #{Enum.join(args, " ")}: #{String.trim(out)}"}
    end
  end
end
