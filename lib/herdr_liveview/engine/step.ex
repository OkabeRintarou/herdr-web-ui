defmodule HerdrLiveView.Engine.Step do
  @moduledoc """
  The contract between the engine and an agent for one step visit: where the task's files live,
  the instruction text, and the JSON result file the agent must write to finish the step.
  """
  alias HerdrLiveView.Tasks.Workflow

  @dir ".herdr-tasks"

  def task_dir(task), do: Path.join([task.workdir, @dir, task.id])

  def key(task), do: "#{task.step}-#{Map.get(task.visits, task.step, 1)}"

  def result_path(task), do: Path.join(task_dir(task), "#{key(task)}.result.json")

  def allowed_verdicts(task), do: Enum.map(Workflow.outcomes(task.workflow, task.step), & &1.on)

  @doc "Reads the result file: `{:ok, verdict, summary}`, `:missing` or `{:invalid, reason}`."
  def read_result(task) do
    allowed = allowed_verdicts(task)

    with {:ok, body} <- File.read(result_path(task)),
         {:ok, %{"verdict" => verdict} = json} <- Jason.decode(body),
         true <- verdict in allowed || {:invalid, "verdict 必须是 #{Enum.join(allowed, " / ")} 之一"} do
      {:ok, verdict, summary(json["summary"])}
    else
      {:error, :enoent} -> :missing
      {:invalid, _} = invalid -> invalid
      {:ok, _} -> {:invalid, "缺少 verdict 字段"}
      {:error, %Jason.DecodeError{}} -> {:invalid, "不是合法的 JSON"}
      {:error, reason} -> {:invalid, inspect(reason)}
    end
  end

  def prompt(task) do
    step = Workflow.step(task.workflow, task.step)
    dir = task_dir(task)

    verdicts =
      for t <- Workflow.outcomes(task.workflow, task.step) do
        "- #{t.on}：#{verdict_hint(t.on, t.to, task.workflow)}"
      end

    """
    你是 AI 小队中的 #{step.role}，负责 task #{task.id}「#{task.title}」中的「#{step.label}」这一步（第 #{Map.get(task.visits, task.step, 1)} 次）。

    需求与验收标准：
    #{blank(task.description, "（无）")}

    本步要做的事：
    #{instructions(step, dir, Map.get(task.visits, task.step, 1))}
    #{feedback(task)}
    task 共享目录：#{dir}
    之前各步的产出都在这个目录里；不要把这个目录提交到 git。

    完成后必须写结果文件 #{result_path(task)}，内容是一个 JSON 对象：
    {"verdict": "<下面之一>", "summary": "一两句话说明结论"}
    可选 verdict：
    #{Enum.join(verdicts, "\n")}

    写好结果文件就结束本轮，不要继续做其他事。
    """
  end

  defp instructions(%{id: "plan"}, dir, _visit),
    do: "阅读相关代码，写出实施方案到 #{dir}/plan.md：目标、改动点、风险、验证方法。若之前有评审意见，请据此修订。"

  defp instructions(%{id: "plan_review"}, dir, _visit),
    do: "评审 #{dir}/plan.md 是否可行、是否覆盖验收标准，意见写到 #{dir}/plan-review.md。"

  defp instructions(%{id: "implement"}, dir, _visit),
    do: "按 #{dir}/plan.md 实现（没有方案就按需求实现），并在当前仓库提交 commit。若发现方案不可行，用 needs_replan 并在 summary 说明原因。"

  defp instructions(%{id: "code_review"}, dir, visit),
    do: "评审本 task 的代码改动（git log / git diff），问题逐条写到 #{dir}/review-#{visit}.md。"

  defp instructions(%{id: "fix"}, dir, _visit),
    do: "根据 #{dir} 中最新的 review-*.md 修复问题并提交 commit。"

  defp instructions(%{id: "test"}, dir, _visit),
    do: "为本次改动补充并运行回归测试，结果写到 #{dir}/test-report.md。"

  defp instructions(step, _dir, _visit), do: "完成「#{step.label}」。"

  defp feedback(task) do
    case Enum.reverse(task.timeline) do
      [_current, %{status: :failed, label: label, output: output} | _] when is_binary(output) ->
        "\n上一步「#{label}」的结论：#{output}\n"

      _ ->
        ""
    end
  end

  defp verdict_hint("done", to, wf), do: "本步完成，进入「#{target_label(to, wf)}」"
  defp verdict_hint("pass", to, wf), do: "通过，进入「#{target_label(to, wf)}」"
  defp verdict_hint(on, to, wf), do: "#{Workflow.verdict_label(on)}，退回「#{target_label(to, wf)}」"

  defp target_label("done", _wf), do: "完成"
  defp target_label(id, wf), do: Workflow.step(wf, id).label

  defp summary(text) when is_binary(text), do: text |> String.trim() |> String.slice(0, 500)
  defp summary(_), do: nil

  defp blank("", default), do: default
  defp blank(text, _default), do: text
end
