defmodule HerdrLiveView.Tasks.TaskRecord do
  @moduledoc """
  Persistence shape of a task. The domain works with plain maps (atom keys, atom enums);
  JSON columns come back with string keys, so `to_task/1` rebuilds them from a whitelist.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias HerdrLiveView.Tasks.Workflow

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "tasks" do
    field(:title, :string)
    field(:description, :string, default: "")
    field(:priority, :string)
    field(:workdir, :string, default: "")
    field(:project_id, :string)
    field(:workflow_source, :string)
    field(:stage, Ecto.Enum, values: [:todo, :plan, :implement, :attention, :done])
    field(:step, :string)
    field(:paused, :boolean, default: false)
    field(:cancelled, :boolean, default: false)
    field(:pane_id, :string)
    field(:agent_status, :string)
    field(:stage_since, :utc_datetime_usec)
    field(:last_bounce, :string)
    field(:workflow, :map)
    field(:proposal, :map)
    field(:previous_workflow, :map)
    field(:visits, :map, default: %{})
    field(:edge_counts, :map, default: %{})
    field(:attention, :map)
    field(:timeline, {:array, :map}, default: [])
    field(:artifacts, {:array, :string}, default: [])
    field(:executor, :string, default: "simulated")
    field(:workspace_id, :string)
    field(:agents, :map, default: %{})

    timestamps()
  end

  @fields ~w(id title description priority workdir project_id workflow_source stage step paused
             cancelled pane_id agent_status stage_since last_bounce workflow proposal
             previous_workflow visits edge_counts attention timeline artifacts executor
             workspace_id agents)a

  @required ~w(id title priority workflow_source stage stage_since)a

  def changeset(record, attrs) do
    record
    |> cast(attrs, @fields)
    |> validate_required(@required)
  end

  def from_task(task) do
    task
    |> Map.take(@fields)
    # validation results are derived and contain tuples, which JSON can't hold
    |> Map.update!(:proposal, &(&1 && %{workflow: &1.workflow}))
  end

  def to_task(%__MODULE__{} = r) do
    r
    |> Map.take(@fields)
    |> Map.merge(%{
      description: r.description || "",
      workdir: r.workdir || "",
      workflow: decode_workflow(r.workflow),
      previous_workflow: decode_workflow(r.previous_workflow),
      proposal: decode_proposal(r.proposal),
      attention: decode_attention(r.attention),
      timeline: Enum.map(r.timeline, &decode_entry/1)
    })
  end

  defp decode_proposal(nil), do: nil

  defp decode_proposal(%{"workflow" => wf}) do
    workflow = decode_workflow(wf)
    %{workflow: workflow, checks: Workflow.validate(workflow)}
  end

  defp decode_workflow(nil), do: nil

  defp decode_workflow(wf) do
    wf
    |> pick(~w(id name version rationale)a)
    |> Map.merge(%{
      source: enum(wf["source"], [:template, :lead]),
      steps:
        Enum.map(wf["steps"], fn step ->
          step
          |> pick(~w(id label role output)a)
          |> Map.put(:phase, enum(step["phase"], [:plan, :implement, :attention]))
        end),
      transitions:
        Map.new(wf["transitions"], fn {from, ts} ->
          {from, Enum.map(ts, &pick(&1, ~w(on to max)a))}
        end)
    })
  end

  defp decode_attention(nil), do: nil

  defp decode_attention(attention) do
    attention
    |> pick(~w(message key verdict)a)
    |> Map.put(
      :kind,
      enum(attention["kind"], [:blocked, :max_loops, :accept, :workflow_approval])
    )
  end

  defp decode_entry(entry) do
    entry
    |> pick(~w(label role minutes output)a)
    |> Map.put(:status, enum(entry["status"], [:running, :done, :failed, :blocked, :waiting]))
  end

  defp pick(map, keys) do
    for key <- keys, Map.has_key?(map, Atom.to_string(key)), into: %{} do
      {key, map[Atom.to_string(key)]}
    end
  end

  defp enum(value, allowed), do: Enum.find(allowed, &(Atom.to_string(&1) == value))
end
