import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :herdr_liveview, HerdrLiveViewWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "FdwJyOgLGDHwyncu2rw0ls3oljt3zUwphCEW3WwSZ4c1uK9j8Ce0Hm/yivWIxLx3",
  server: false

config :herdr_liveview, HerdrLiveView.Repo,
  database: Path.expand("../_build/herdr_liveview_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

config :herdr_liveview,
  start_herdr: false,
  start_engine: false,
  engine_herdr: HerdrLiveView.FakeHerdr,
  migrate_on_boot: false,
  access_token: nil,
  herdr_socket_path: Path.join(System.tmp_dir!(), "herdr-liveview-test-missing.sock")

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
