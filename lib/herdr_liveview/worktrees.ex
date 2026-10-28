defmodule HerdrLiveView.Worktrees do
  @moduledoc """
  Each herdr-executed task in a git project works in its own worktree
  (`<project>/.herdr-worktrees/<task>` on branch `herdr/<task>`), so parallel tasks don't
  trample each other. Non-git folders are worked on in place. Runs on the project's host.
  """
  alias HerdrLiveView.Hosts.Shell

  @dir ".herdr-worktrees"
  @ignored [".herdr-worktrees/", ".herdr-tasks/"]

  def branch(task), do: "herdr/#{task.id}"
  def path(project, task), do: Path.join([project.path, @dir, task.id])

  @doc "Makes sure the task has its worktree; returns the task pointed at it."
  def ensure(project, task) do
    host = host(project)

    cond do
      task.worktree && Shell.dir?(host, task.worktree) -> {:ok, task}
      not git_repo?(host, project.path) -> {:ok, task}
      true -> create(host, project, task)
    end
  end

  @doc "Removes the worktree directory; the branch (and its commits) stays."
  def remove(project, %{worktree: dir} = task) when is_binary(dir) do
    with {:ok, _} <-
           Shell.git(host(project), project.path, ["worktree", "remove", "--force", dir]) do
      {:ok, %{task | worktree: nil}}
    end
  end

  def remove(_project, task), do: {:ok, task}

  def git_repo?(host, path) do
    Shell.dir?(host, path) and
      match?({:ok, "true"}, Shell.git(host, path, ["rev-parse", "--is-inside-work-tree"]))
  end

  defp create(host, project, task) do
    dir = path(project, task)
    branch = branch(task)
    git = &Shell.git(host, project.path, &1)

    args =
      if ref?(git, "refs/heads/#{branch}"),
        do: ["worktree", "add", dir, branch],
        else: ["worktree", "add", "-b", branch, dir, base(git, project)]

    with :ok <- ignore(host, git),
         {:ok, prefix} <- git.(["rev-parse", "--show-prefix"]),
         {:ok, _} <- git.(["worktree", "prune"]),
         {:ok, _} <- git.(args) do
      # a project may be a subfolder of its repo; agents work in the same subfolder
      {:ok, %{task | workdir: Path.join(dir, prefix), worktree: dir, branch: branch}}
    end
  end

  defp base(git, project) do
    if ref?(git, "refs/heads/#{project.default_branch}"),
      do: project.default_branch,
      else: "HEAD"
  end

  defp ref?(git, ref), do: match?({:ok, _}, git.(["rev-parse", "--verify", "--quiet", ref]))

  # info/exclude rather than .gitignore: nothing to commit, and it covers every worktree.
  defp ignore(host, git) do
    with {:ok, common} <- git.(["rev-parse", "--path-format=absolute", "--git-common-dir"]) do
      file = Path.join([common, "info", "exclude"])

      current =
        case Shell.read(host, file) do
          {:ok, body} -> body
          _ -> ""
        end

      missing = Enum.reject(@ignored, &(&1 in String.split(current, "\n")))

      if missing != [] do
        prefix = if current == "" or String.ends_with?(current, "\n"), do: "", else: "\n"
        Shell.append!(host, file, prefix <> Enum.join(missing, "\n") <> "\n")
      end

      :ok
    end
  end

  defp host(project), do: Map.get(project, :host)
end
