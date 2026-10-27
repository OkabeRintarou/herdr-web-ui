defmodule HerdrLiveView.Tasks.Runner do
  @moduledoc """
  Pure task state transitions driven by workflow verdicts. The demo board calls these
  directly; the real engine will call them from agent results.
  """
  alias HerdrLiveView.Tasks.Workflow

  def new(attrs, now \\ DateTime.utc_now()) do
    source = attrs["workflow"] || "lead"

    %{
      id:
        attrs["id"] ||
          "t-" <> Base.encode32(:crypto.strong_rand_bytes(4), case: :lower, padding: false),
      title: attrs["title"],
      description: attrs["description"] || "",
      priority: attrs["priority"] || "P2",
      repo: attrs["repo"] || "",
      workflow_source: source,
      workflow: Workflow.template(source),
      proposal: nil,
      previous_workflow: nil,
      step: nil,
      stage: :todo,
      visits: %{},
      edge_counts: %{},
      attention: nil,
      paused: false,
      cancelled: false,
      pane_id: attrs["pane_id"],
      agent_status: nil,
      stage_since: now,
      timeline: [],
      artifacts: [],
      last_bounce: nil
    }
  end

  def start(%{workflow: nil} = task, now), do: design(task, now)
  def start(task, now), do: enter(task, Workflow.first_step(task.workflow), now)

  def design(task, now) do
    %{task | step: "design", stage: :plan, attention: nil, agent_status: "working", paused: false}
    |> Map.put(:stage_since, now)
    |> append(%{label: "设计流程", role: "lead", status: :running})
  end

  def propose(task, workflow, now) do
    version = workflow.version

    %{task | proposal: %{workflow: workflow, checks: Workflow.validate(workflow)}}
    |> close_last(:done, "workflow v#{version}", now)
    |> Map.merge(%{
      stage: :attention,
      agent_status: "idle",
      stage_since: now,
      attention: %{kind: :workflow_approval, message: "lead 提交了流程 v#{version}，请审批后开工"}
    })
  end

  def approve_workflow(%{proposal: %{workflow: workflow}} = task, now) do
    %{task | workflow: workflow, proposal: nil, attention: nil}
    |> enter(Workflow.first_step(workflow), now)
  end

  def redesign(%{proposal: %{workflow: workflow}} = task, now) do
    %{task | previous_workflow: workflow, proposal: nil} |> design(now)
  end

  def use_template(task, template_id, now) do
    %{
      task
      | workflow: Workflow.template(template_id),
        workflow_source: template_id,
        proposal: nil
    }
    |> Map.put(:attention, nil)
    |> start(now)
  end

  def verdict(%{workflow: workflow, step: from} = task, verdict, note, now) do
    transition = Enum.find(Workflow.outcomes(workflow, from), &(&1.on == verdict))
    key = "#{from}:#{verdict}"
    count = Map.get(task.edge_counts, key, 0)
    step = Workflow.step(workflow, from)

    cond do
      transition == nil ->
        task

      transition.max && count >= transition.max ->
        %{
          task
          | stage: :attention,
            agent_status: "idle",
            attention: %{
              kind: :max_loops,
              key: key,
              verdict: verdict,
              message:
                "「#{step.label}」→ #{Workflow.verdict_label(verdict)} 已达 #{transition.max} 次上限"
            }
        }

      true ->
        passed? = verdict in ~w(done pass)
        output = Enum.join(Enum.reject([Workflow.verdict_label(verdict), note], &is_nil/1), "：")

        task =
          task
          |> close_last(if(passed?, do: :done, else: :failed), output, now)
          |> Map.update!(:edge_counts, &Map.update(&1, key, 1, fn n -> n + 1 end))
          |> add_artifact(passed? && step.output)
          |> Map.put(:attention, nil)

        task =
          if passed?,
            do: task,
            else: %{task | last_bounce: "#{step.label} → #{Workflow.verdict_label(verdict)}"}

        if transition.to == "done",
          do: %{task | step: nil, stage: :done, agent_status: nil, stage_since: now},
          else: enter(task, transition.to, now)
    end
  end

  @doc "Grants one more pass over a capped loop and retries the verdict that hit the cap."
  def extend(%{attention: %{kind: :max_loops, key: key, verdict: verdict}} = task, now) do
    task
    |> Map.update!(:edge_counts, &Map.update!(&1, key, fn n -> n - 1 end))
    |> verdict(verdict, "人工放行一轮", now)
  end

  def jump(task, step_id, now) do
    task
    |> close_last(:failed, "人工退回到「#{Workflow.step(task.workflow, step_id).label}」", now)
    |> Map.put(:attention, nil)
    |> enter(step_id, now)
  end

  def resume(task) do
    %{task | attention: nil, agent_status: "working", stage: stage_of(task)}
    |> mark_last(:running)
  end

  def toggle_pause(task), do: %{task | paused: not task.paused}

  def cancel(task, now) do
    %{task | stage: :done, cancelled: true, attention: nil, agent_status: nil, stage_since: now}
  end

  def block(task, message) do
    %{
      task
      | stage: :attention,
        agent_status: "blocked",
        attention: %{kind: :blocked, message: message}
    }
    |> mark_last(:blocked)
  end

  def current_step(%{step: "design"}), do: %{id: "design", label: "设计流程", role: "lead"}
  def current_step(%{workflow: nil}), do: nil

  def current_step(%{workflow: workflow, step: id}) when is_binary(id),
    do: Workflow.step(workflow, id)

  def current_step(_task), do: nil

  def agent_step?(task) do
    case current_step(task) do
      %{role: role} -> role not in ["human", "lead"]
      nil -> false
    end
  end

  defp enter(task, step_id, now) do
    step = Workflow.step(task.workflow, step_id)
    human? = step.role == "human"

    %{
      task
      | step: step_id,
        stage: step.phase,
        paused: false,
        stage_since: now,
        agent_status: if(human?, do: nil, else: "working"),
        visits: Map.update(task.visits, step_id, 1, &(&1 + 1)),
        attention: if(human?, do: %{kind: :accept, message: "「#{step.label}」：请确认结果"})
    }
    |> append(%{
      label: step.label,
      role: step.role,
      status: if(human?, do: :waiting, else: :running)
    })
  end

  defp stage_of(task) do
    case current_step(task) do
      %{phase: phase} -> phase
      %{id: "design"} -> :plan
      _ -> task.stage
    end
  end

  defp append(task, entry) do
    entry = Map.merge(%{minutes: 0, output: nil}, entry)
    %{task | timeline: task.timeline ++ [entry]}
  end

  defp close_last(%{timeline: []} = task, _status, _output, _now), do: task

  defp close_last(task, status, output, now) do
    minutes = max(DateTime.diff(now, task.stage_since, :minute), 1)

    %{
      task
      | timeline:
          List.update_at(
            task.timeline,
            -1,
            &%{&1 | status: status, output: output, minutes: minutes}
          )
    }
  end

  defp mark_last(%{timeline: []} = task, _status), do: task

  defp mark_last(task, status),
    do: %{task | timeline: List.update_at(task.timeline, -1, &%{&1 | status: status})}

  defp add_artifact(task, artifact) when is_binary(artifact) do
    if artifact in task.artifacts,
      do: task,
      else: %{task | artifacts: task.artifacts ++ [artifact]}
  end

  defp add_artifact(task, _), do: task
end
