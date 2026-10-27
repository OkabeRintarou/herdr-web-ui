defmodule HerdrLiveView.DataCase do
  @moduledoc "Test case for code that touches the Repo; each test runs in a rolled-back sandbox."
  use ExUnit.CaseTemplate

  using do
    quote do
      alias HerdrLiveView.Repo
      import HerdrLiveView.DataCase
    end
  end

  setup tags do
    setup_sandbox(tags)
    :ok
  end

  # SQLite serialises writers, so DB tests should run with `async: false` (shared mode).
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(HerdrLiveView.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
