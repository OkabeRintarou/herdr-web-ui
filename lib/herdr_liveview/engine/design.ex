defmodule HerdrLiveView.Engine.Design do
  @moduledoc """
  The lead's design step: the prompt that asks for a workflow plus member assignments, and
  reading and checking the plan file the lead writes. Only plans that pass every check reach
  a human for approval; the rest go back to the lead with the reasons.
  """
  alias HerdrLiveView.Engine.Step
  alias HerdrLiveView.Hosts.Shell
  alias HerdrLiveView.Tasks.Workflow
  alias HerdrLiveView.Teams

  @step_id ~r/^[a-z][a-z0-9_]{0,31}$/
  @verdict ~r/^[a-z][a-z_]{0,31}$/

  def prompt(task, team) do
    version = Map.get(task.visits, "design", 1)

    """
    你是 AI 小队的 lead，负责为 task #{task.id}「#{task.title}」设计执行流程并分配成员（第 #{version} 版）。

    需求与验收标准：
    #{blank(task.description, "（无）")}

    工作目录：#{task.workdir}
    可以阅读其中的代码和资料来了解情况，但不要修改任何文件。

    小队成员：
    #{roster(team)}
    另有 human 表示需要人来确认的步骤（例如最终验收）。
    #{templates(team)}#{previous(task)}#{Step.feedback(task)}
    用你的写文件工具（不要用 shell 命令）把流程写成 JSON 文件 #{Step.result_path(task)}，格式示例：
    #{example()}

    规则：
    - steps 的第一个是起点；transitions 里 "to": "done" 表示结束。
    - role 只能用上面成员的角色或 human；phase 取 plan（准备、方案类）或 implement（执行类）。
    - instructions 写清这一步做什么、产出写到哪里；可用 {dir} 表示 task 共享目录、{visit} 表示第几次进入该步。
    - 每一步都要有出口；会回到之前步骤的循环里至少有一条边带 "max" 上限。
    - on 是这一步可以给出的结论，常用 done、pass、changes_requested、needs_replan、reject。
    - 同一角色有多名成员时，用 assignments 指定由谁来做；不写则用该角色的第一名成员。

    写好文件就结束本轮，不要做其他事。
    """
  end

  @doc "`{:ok, workflow}`, `:missing` or `{:invalid, reason}`."
  def read_plan(task, team, host \\ nil) do
    with {:ok, body} <- Shell.read(host, Step.result_path(task)),
         {:ok, plan} <- decode(body),
         {:ok, workflow} <- build(plan, task),
         :ok <- check(workflow, team) do
      {:ok, workflow}
    else
      {:error, :enoent} -> :missing
      {:error, reason} when is_atom(reason) -> {:invalid, inspect(reason)}
      {:invalid, _} = invalid -> invalid
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{"steps" => [_ | _], "transitions" => %{}} = plan} -> {:ok, plan}
      {:ok, _} -> {:invalid, "需要一个包含 steps（非空数组）和 transitions（对象）的 JSON 对象"}
      {:error, _} -> {:invalid, "不是合法的 JSON"}
    end
  end

  defp build(plan, task) do
    with :ok <- check_steps(plan["steps"]),
         :ok <- check_transitions(plan["transitions"]),
         :ok <- check_assignments(plan["assignments"]) do
      steps =
        Enum.map(plan["steps"], fn step ->
          phase = if step["role"] == "human", do: "attention", else: step["phase"]
          Map.put(step, "phase", phase)
        end)

      workflow =
        Workflow.decode(%{
          "id" => "lead-#{task.id}",
          "name" => text(plan["name"]) || "lead 设计",
          "source" => "lead",
          "version" => Map.get(task.visits, "design", 1),
          "rationale" => text(plan["rationale"]),
          "assignments" => plan["assignments"] || %{},
          "steps" => steps,
          "transitions" => plan["transitions"]
        })

      {:ok, workflow}
    end
  end

  defp check_steps(steps) do
    bad =
      Enum.reject(steps, fn step ->
        is_map(step) and is_binary(step["id"]) and String.match?(step["id"], @step_id) and
          step["id"] not in ["done", "design"] and text(step["label"]) != nil and
          Workflow.valid_role?(step["role"]) and
          (step["role"] == "human" or step["phase"] in ["plan", "implement"]) and
          (is_nil(step["instructions"]) or is_binary(step["instructions"]))
      end)

    ids = Enum.map(steps, &(is_map(&1) && &1["id"]))

    cond do
      bad != [] ->
        {:invalid,
         "步骤格式不对（id 需小写字母开头、label 非空、role 合法、phase 为 plan 或 implement）：" <>
           Enum.map_join(bad, "、", &inspect(&1["id"] || &1))}

      length(Enum.uniq(ids)) != length(ids) ->
        {:invalid, "步骤 id 有重复"}

      true ->
        :ok
    end
  end

  defp check_transitions(transitions) do
    ok? =
      Enum.all?(transitions, fn {_from, edges} ->
        is_list(edges) and
          Enum.all?(edges, fn edge ->
            is_map(edge) and is_binary(edge["on"]) and String.match?(edge["on"], @verdict) and
              is_binary(edge["to"]) and
              (is_nil(edge["max"]) or (is_integer(edge["max"]) and edge["max"] > 0))
          end)
      end)

    if ok?,
      do: :ok,
      else: {:invalid, "transitions 的每条边需要 on（小写结论名）、to（步骤 id 或 done），max 可选且为正整数"}
  end

  defp check_assignments(nil), do: :ok

  defp check_assignments(assignments) when is_map(assignments) do
    if Enum.all?(assignments, fn {role, name} -> is_binary(role) and is_binary(name) end),
      do: :ok,
      else: {:invalid, "assignments 需要是 {\"角色\": \"成员名\"}"}
  end

  defp check_assignments(_), do: {:invalid, "assignments 需要是 {\"角色\": \"成员名\"}"}

  defp check(workflow, team) do
    failed = for {label, false} <- Workflow.validate(workflow), do: label
    missing = Teams.missing_roles(team, workflow)

    wrong =
      for {role, name} <- workflow.assignments,
          not Enum.any?(team.members, &(&1.role == role and &1.name == name)),
          do: "#{role} → #{name}"

    problems =
      Enum.concat([
        failed,
        if(missing != [], do: ["Team 里没有这些角色：#{Enum.join(missing, "、")}"], else: []),
        if(wrong != [], do: ["assignments 里的成员不存在或角色不符：#{Enum.join(wrong, "、")}"], else: [])
      ])

    if problems == [], do: :ok, else: {:invalid, "未通过检查：" <> Enum.join(problems, "；")}
  end

  defp roster(team) do
    Enum.map_join(team.members, "\n", fn m ->
      extras = Enum.reject([blank(m.duty, nil), blank(m.notes, nil)], &is_nil/1)
      "- #{m.name}（角色 #{m.role}，#{m.agent_kind}）" <> Enum.map_join(extras, "", &"；#{&1}")
    end)
  end

  defp templates(team) do
    case Teams.workflows(team) do
      [] ->
        ""

      workflows ->
        body = Enum.map_join(workflows, "\n", &"- #{&1.name}：#{Jason.encode!(shape(&1))}")
        "\n本 Team 已有的流程模板（可参考或沿用）：\n#{body}\n"
    end
  end

  defp previous(%{previous_workflow: %{} = wf}),
    do: "\n上一版流程（v#{wf.version}）：\n#{Jason.encode!(shape(wf))}\n"

  defp previous(_task), do: ""

  defp shape(wf) do
    %{
      steps: Enum.map(wf.steps, &Map.take(&1, [:id, :label, :role, :phase, :instructions])),
      transitions: wf.transitions,
      assignments: Map.get(wf, :assignments) || %{}
    }
  end

  defp example do
    Jason.encode!(
      %{
        name: "流程名称",
        rationale: "为什么这样设计",
        steps: [
          %{
            id: "research",
            label: "调研",
            role: "<角色>",
            phase: "plan",
            instructions: "……写到 {dir}/research.md"
          },
          %{id: "review", label: "评审", role: "<角色>", phase: "implement", instructions: "……"},
          %{id: "accept", label: "验收", role: "human"}
        ],
        transitions: %{
          research: [%{on: "done", to: "review"}],
          review: [
            %{on: "pass", to: "accept"},
            %{on: "changes_requested", to: "research", max: 2}
          ],
          accept: [%{on: "pass", to: "done"}, %{on: "reject", to: "research", max: 1}]
        },
        assignments: %{"<角色>": "<成员名>"}
      },
      pretty: true
    )
  end

  defp text(value) when is_binary(value), do: blank(String.trim(value), nil)
  defp text(_), do: nil

  defp blank("", default), do: default
  defp blank(value, _default), do: value
end
