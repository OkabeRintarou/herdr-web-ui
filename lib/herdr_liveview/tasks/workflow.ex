defmodule HerdrLiveView.Tasks.Workflow do
  @moduledoc """
  Workflows are step graphs: each step is run by a role and ends with a verdict;
  transitions map `{step, verdict}` to the next step (or `"done"`), optionally capped by `max`.
  Roles are whatever the team defines; `human` is the only built-in one. A step's
  `instructions` may use `{dir}` (the task's shared folder) and `{visit}`.
  """

  @verdicts %{
    "done" => "完成",
    "pass" => "通过",
    "changes_requested" => "要修改",
    "needs_replan" => "重新规划",
    "reject" => "退回"
  }

  def verdict_label(verdict), do: Map.get(@verdicts, verdict, verdict)

  @plan "阅读相关代码，写出实施方案到 {dir}/plan.md：目标、改动点、风险、验证方法。若之前有评审意见，请据此修订。"
  @plan_review "评审 {dir}/plan.md 是否可行、是否覆盖验收标准，意见写到 {dir}/plan-review.md。"
  @implement "按 {dir}/plan.md 实现（没有方案就按需求实现），并在当前仓库提交 commit。若发现方案不可行，用 needs_replan 并在 summary 说明原因。"
  @code_review "评审本 task 的代码改动（git log / git diff），问题逐条写到 {dir}/review-{visit}.md。"
  @fix "根据 {dir} 中最新的 review-*.md 修复问题并提交 commit。"
  @test "为本次改动补充并运行回归测试，结果写到 {dir}/test-report.md。"

  @doc "Software-team presets; teams get their own copies to use and change."
  def templates, do: [standard(), quick()]

  def template("standard"), do: standard()
  def template("quick"), do: quick()
  def template(_), do: nil

  def standard do
    %{
      id: "standard",
      name: "标准流程",
      source: :template,
      version: 1,
      steps: [
        step("plan", "规划", "architect", :plan, "plan.md", @plan),
        step("plan_review", "规划评审", "reviewer", :plan, "plan-review.json", @plan_review),
        step("implement", "实现", "coder", :implement, "diff", @implement),
        step("code_review", "代码评审", "reviewer", :implement, "review.json", @code_review),
        step("fix", "修复", "coder", :implement, "diff", @fix),
        step("accept", "验收", "human", :attention, nil)
      ],
      transitions: %{
        "plan" => [t("done", "plan_review")],
        "plan_review" => [t("pass", "implement"), t("changes_requested", "plan", 2)],
        "implement" => [t("done", "code_review"), t("needs_replan", "plan", 1)],
        "code_review" => [
          t("pass", "accept"),
          t("changes_requested", "fix", 3),
          t("needs_replan", "plan", 1)
        ],
        "fix" => [t("done", "code_review")],
        "accept" => [t("pass", "done"), t("reject", "fix", 2)]
      }
    }
  end

  def quick do
    %{
      id: "quick",
      name: "快速修复",
      source: :template,
      version: 1,
      steps: [
        step("implement", "实现", "coder", :implement, "diff", @implement),
        step("code_review", "代码评审", "reviewer", :implement, "review.json", @code_review),
        step("fix", "修复", "coder", :implement, "diff", @fix),
        step("accept", "验收", "human", :attention, nil)
      ],
      transitions: %{
        "implement" => [t("done", "code_review")],
        "code_review" => [t("pass", "accept"), t("changes_requested", "fix", 2)],
        "fix" => [t("done", "code_review")],
        "accept" => [t("pass", "done"), t("reject", "fix", 1)]
      }
    }
  end

  @doc "Stand-in for the lead agent's output until a real lead pane writes workflow.yaml."
  def propose(task, version \\ 1, feedback \\ nil) do
    base = %{
      id: "lead-#{task.id}",
      name: "lead 设计",
      source: :lead,
      version: version
    }

    if version == 1 do
      Map.merge(base, %{
        rationale: "「#{task.title}」改动面较大且需要验证行为：先规划并评审方案，实现后由 tester 补回归用例，再做代码评审。",
        steps: [
          step("plan", "规划", "architect", :plan, "plan.md", @plan),
          step("plan_review", "规划评审", "reviewer", :plan, "plan-review.json", @plan_review),
          step("implement", "实现", "coder", :implement, "diff", @implement),
          step("test", "回归测试", "tester", :implement, "test-report.md", @test),
          step("code_review", "代码评审", "reviewer", :implement, "review.json", @code_review),
          step("fix", "修复", "coder", :implement, "diff", @fix),
          step("accept", "验收", "human", :attention, nil)
        ],
        transitions: %{
          "plan" => [t("done", "plan_review")],
          "plan_review" => [t("pass", "implement"), t("changes_requested", "plan", 2)],
          "implement" => [t("done", "test"), t("needs_replan", "plan", 1)],
          "test" => [t("pass", "code_review"), t("changes_requested", "fix", 2)],
          "code_review" => [
            t("pass", "accept"),
            t("changes_requested", "fix", 3),
            t("needs_replan", "plan", 1)
          ],
          "fix" => [t("done", "test")],
          "accept" => [t("pass", "done"), t("reject", "fix", 2)]
        }
      })
    else
      Map.merge(base, %{
        rationale: "根据意见调整（#{feedback || "无"}）：去掉规划评审，测试并入代码评审，缩短反馈环。",
        steps: [
          step("plan", "规划", "architect", :plan, "plan.md", @plan),
          step("implement", "实现", "coder", :implement, "diff", @implement),
          step("code_review", "代码评审", "reviewer", :implement, "review.json", @code_review),
          step("fix", "修复", "coder", :implement, "diff", @fix),
          step("accept", "验收", "human", :attention, nil)
        ],
        transitions: %{
          "plan" => [t("done", "implement")],
          "implement" => [t("done", "code_review"), t("needs_replan", "plan", 1)],
          "code_review" => [
            t("pass", "accept"),
            t("changes_requested", "fix", 3),
            t("needs_replan", "plan", 1)
          ],
          "fix" => [t("done", "code_review")],
          "accept" => [t("pass", "done"), t("reject", "fix", 2)]
        }
      })
    end
  end

  def first_step(%{steps: [first | _]}), do: first.id

  def step(workflow, id), do: Enum.find(workflow.steps, &(&1.id == id))

  def outcomes(workflow, id), do: Map.get(workflow.transitions, id, [])

  def index(workflow, id) do
    if id == "done",
      do: length(workflow.steps),
      else: Enum.find_index(workflow.steps, &(&1.id == id))
  end

  @doc "Hard checks the engine runs before a proposed workflow may be approved."
  def validate(workflow) do
    ids = MapSet.new(workflow.steps, & &1.id)

    edges =
      for {from, ts} <- workflow.transitions, t <- ts, do: {from, t}

    [
      {"每一步都指定了角色", Enum.all?(workflow.steps, &valid_role?(&1.role))},
      {"每一步都有出口", Enum.all?(workflow.steps, &(outcomes(workflow, &1.id) != []))},
      {"跳转目标都存在", Enum.all?(edges, fn {_, t} -> t.to == "done" or t.to in ids end)},
      {"每个循环都有上限", uncapped_acyclic?(workflow)},
      {"能到达完成", "done" in reachable(workflow)}
    ]
  end

  def diff(old, new) do
    old_ids = MapSet.new(old.steps, & &1.id)
    new_ids = MapSet.new(new.steps, & &1.id)

    %{
      added: for(s <- new.steps, s.id not in old_ids, do: s.label),
      removed: for(s <- old.steps, s.id not in new_ids, do: s.label)
    }
  end

  # A loop is bounded as long as at least one of its edges carries a `max`.
  defp uncapped_acyclic?(workflow) do
    graph =
      Map.new(workflow.transitions, fn {from, ts} ->
        {from, for(t <- ts, is_nil(t.max), do: t.to)}
      end)

    Enum.all?(Map.keys(graph), &(not cycle_from?(graph, &1, MapSet.new())))
  end

  defp cycle_from?(graph, node, path) do
    if node in path do
      true
    else
      path = MapSet.put(path, node)
      Enum.any?(Map.get(graph, node, []), &cycle_from?(graph, &1, path))
    end
  end

  defp reachable(workflow) do
    Stream.unfold({[first_step(workflow)], MapSet.new()}, fn
      {[], _seen} ->
        nil

      {[id | rest], seen} ->
        if id in seen do
          {nil, {rest, seen}}
        else
          next = Enum.map(outcomes(workflow, id), & &1.to)
          {id, {rest ++ next, MapSet.put(seen, id)}}
        end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp step(id, label, role, phase, output, instructions \\ nil),
    do: %{
      id: id,
      label: label,
      role: role,
      phase: phase,
      output: output,
      instructions: instructions
    }

  defp t(on, to, max \\ nil), do: %{on: on, to: to, max: max}

  @role_format ~r/^[a-z][a-z0-9-]{0,23}$/

  def role_format, do: @role_format
  def valid_role?(role), do: is_binary(role) and String.match?(role, @role_format)

  @doc "Rebuilds a workflow from its JSON form (string keys), keeping only known fields."
  def decode(nil), do: nil

  def decode(wf) do
    wf
    |> pick(~w(id name version rationale)a)
    |> Map.merge(%{
      source: enum(wf["source"], [:template, :lead]),
      steps:
        Enum.map(wf["steps"], fn step ->
          step
          |> pick(~w(id label role output instructions)a)
          |> Map.put_new(:instructions, nil)
          |> Map.put(:phase, enum(step["phase"], [:plan, :implement, :attention]))
        end),
      transitions:
        Map.new(wf["transitions"], fn {from, ts} ->
          {from, Enum.map(ts, &pick(&1, ~w(on to max)a))}
        end)
    })
  end

  @doc "The JSON form of a workflow, as stored in the database."
  def encode(wf), do: wf |> Jason.encode!() |> Jason.decode!()

  defp pick(map, keys) do
    for key <- keys, Map.has_key?(map, Atom.to_string(key)), into: %{} do
      {key, map[Atom.to_string(key)]}
    end
  end

  defp enum(value, allowed), do: Enum.find(allowed, &(Atom.to_string(&1) == value))
end
