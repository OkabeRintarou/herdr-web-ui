defmodule HerdrLiveView.Teams.Member do
  @moduledoc """
  A member template: which agent CLI plays a role, with what arguments. Each task starts its
  own agent instance from it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(copilot claude codex opencode gemini cursor amp kimi qwen)

  def kinds, do: @kinds

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "team_members" do
    field(:name, :string)
    field(:role, :string)
    field(:agent_kind, :string)
    field(:agent_args, :string, default: "")
    field(:duty, :string, default: "")
    field(:notes, :string, default: "")
    field(:lifetime, :string, default: "resident")
    belongs_to(:team, HerdrLiveView.Teams.Team, type: :string)

    timestamps()
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [
      :id,
      :team_id,
      :name,
      :role,
      :agent_kind,
      :agent_args,
      :duty,
      :notes,
      :lifetime
    ])
    |> update_change(:agent_args, &String.trim/1)
    |> validate_required([:id, :team_id, :name, :role, :agent_kind])
    |> validate_format(:name, ~r/^[a-z][a-z0-9-]{0,15}$/,
      message: "小写字母开头，只含小写字母、数字和 -，最长 16 个字符"
    )
    |> validate_format(:role, HerdrLiveView.Tasks.Workflow.role_format(),
      message: "小写字母开头，只含小写字母、数字和 -，最长 24 个字符"
    )
    |> validate_exclusion(:role, ["human"], message: "human 代表人工步骤，不能分给成员")
    |> validate_inclusion(:agent_kind, @kinds)
    |> validate_inclusion(:lifetime, ~w(resident ephemeral))
    |> validate_change(:agent_args, fn :agent_args, args ->
      try do
        OptionParser.split(args)
        []
      rescue
        _ -> [agent_args: "引号不匹配"]
      end
    end)
    |> unique_constraint([:team_id, :name], message: "Team 内已有同名成员")
  end
end
