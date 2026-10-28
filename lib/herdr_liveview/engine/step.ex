defmodule HerdrLiveView.Engine.Step do
  @moduledoc """
  The contract between the engine and an agent for one step visit: where the task's files live,
  the instruction text, and the JSON result file the agent must write to finish the step.
  """
  alias HerdrLiveView.Tasks.Workflow

  @dir ".herdr-tasks"

  def task_dir(task), do: Path.join([task.workdir, @dir, task.id])

  def key(task), do: "#{task.step}-#{Map.get(task.visits, task.step, 1)}"

  def result_path(%{step: "design"} = task),
    do: Path.join(task_dir(task), "#{key(task)}.plan.json")

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

  def prompt(task, member \\ nil) do
    step = Workflow.step(task.workflow, task.step)
    dir = task_dir(task)
    visit = Map.get(task.visits, task.step, 1)

    verdicts =
      for t <- Workflow.outcomes(task.workflow, task.step) do
        "- #{t.on}：#{verdict_hint(t.on, t.to, task.workflow)}"
      end

    """
    你是 AI 小队中的 #{step.role}，负责 task #{task.id}「#{task.title}」中的「#{step.label}」这一步（第 #{visit} 次）。
    #{duty(member)}
    需求与验收标准：
    #{blank(task.description, "（无）")}

    本步要做的事：
    #{instructions(step, dir, visit)}
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

  defp duty(%{duty: duty}) when is_binary(duty) and duty != "", do: "你的职责：#{duty}\n"
  defp duty(_member), do: ""

  defp instructions(%{instructions: text}, dir, visit) when is_binary(text) and text != "" do
    text
    |> String.replace("{dir}", dir)
    |> String.replace("{visit}", to_string(visit))
  end

  defp instructions(step, _dir, _visit), do: "完成「#{step.label}」。"

  def feedback(task) do
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
