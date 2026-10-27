defmodule HerdrLiveView.Repo do
  # The adapter is compile-time in Ecto; switching to PostgreSQL means adding :postgrex,
  # setting `config :herdr_liveview, :repo_adapter, Ecto.Adapters.Postgres` and DATABASE_URL.
  use Ecto.Repo,
    otp_app: :herdr_liveview,
    adapter: Application.compile_env(:herdr_liveview, :repo_adapter, Ecto.Adapters.SQLite3)
end
