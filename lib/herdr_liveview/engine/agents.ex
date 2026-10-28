defmodule HerdrLiveView.Engine.Agents do
  @moduledoc """
  Agent instance lifecycle for a task. `task.agents[role]` records the live instance
  (`name`, `pane_id`, `member`, `n`, `uses`, `last_used`, `head`); an entry without a name
  means the role's last instance was recycled and the next one is `n + 1`.

  An instance is replaced (a fresh one starts with a handoff note) after `@max_uses` prompts,
  when its member assignment changed, or when flagged `retire` (replan, or a human asked).
  """
  alias HerdrLiveView.Engine.Step

  @max_uses 3
  @wake_after_s 30 * 60

  def max_uses, do: @max_uses

  # herdr agent names: [a-z][a-z0-9_-]{0,31}
  def instance_name(task, member, n) do
    "#{task.id}-#{member}-#{n}"
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "-")
    |> String.slice(0, 32)
  end

  def live?(agent), do: is_map(agent) and is_binary(agent["name"])

  def replace?(agent, member) do
    live?(agent) and
      (agent["retire"] == true or (agent["uses"] || 0) >= @max_uses or
         (is_binary(agent["member"]) and agent["member"] != member))
  end

  @doc "The entry left behind once an instance's pane is closed."
  def recycled(agent), do: %{"n" => (agent && agent["n"]) || 1}

  def next_n(nil), do: 1
  def next_n(agent), do: if(live?(agent), do: agent["n"] || 1, else: (agent["n"] || 0) + 1)

  def retire_all(agents),
    do: Map.new(agents, fn {role, a} -> {role, Map.put(a, "retire", true)} end)

  def used(agent, task, now) do
    Map.merge(agent, %{
      "step" => Step.key(task),
      "uses" => (agent["uses"] || 0) + 1,
      "last_used" => DateTime.to_unix(now),
      "head" => head(task.workdir)
    })
  end

  @doc "Told to a fresh instance that takes over a role someone already worked on."
  def handoff(task, agent) do
    if (agent["n"] || 1) > 1 do
      done =
        task.timeline
        |> Enum.filter(&(&1.status in [:done, :failed]))
        |> Enum.map_join("\n", &"- #{&1.label}（#{&1.role}）：#{&1.output || "完成"}")

      """
      你接替了之前在本 task 中担任这个角色的 agent。先阅读 task 共享目录 #{Step.task_dir(task)} 里已有的产出和 git log，了解进展再开始。
      目前的进展：
      #{if done == "", do: "（还没有完成的步骤）", else: done}

      """
    else
      ""
    end
  end

  @doc "Told to an instance coming back after a long pause or after others committed."
  def wake_up(task, agent, now) do
    idle_s = if agent["last_used"], do: DateTime.to_unix(now) - agent["last_used"], else: 0
    head = head(task.workdir)

    commits =
      if agent["head"] && head && agent["head"] != head, do: log(task.workdir, agent["head"])

    cond do
      commits not in [nil, ""] ->
        "自你上次在本 task 工作以来，仓库有了新的提交：\n#{commits}\n先看一下这些改动（git show / git diff #{String.slice(agent["head"], 0, 12)}..HEAD）再开始。\n\n"

      idle_s > @wake_after_s ->
        "距离你上次在本 task 工作已过去 #{div(idle_s, 60)} 分钟，先快速回顾 #{Step.task_dir(task)} 中的最新产出再开始。\n\n"

      true ->
        ""
    end
  end

  defp head(dir) do
    case System.cmd("git", ["-C", dir, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp log(dir, since) do
    case System.cmd("git", ["-C", dir, "log", "--oneline", "-n", "20", "#{since}..HEAD"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end
end
