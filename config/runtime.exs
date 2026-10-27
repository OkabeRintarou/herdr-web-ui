import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/herdr_liveview start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :herdr_liveview, HerdrLiveViewWeb.Endpoint, server: true
end

config :herdr_liveview, HerdrLiveViewWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() != :test do
  # herdr injects HERDR_SOCKET_PATH into plugin processes; fall back to the default session.
  config :herdr_liveview,
    herdr_socket_path:
      System.get_env("HERDR_SOCKET_PATH") || Path.expand("~/.config/herdr/herdr.sock"),
    access_token: System.get_env("HERDR_LIVEVIEW_TOKEN")
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :herdr_liveview, HerdrLiveViewWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/herdr_liveview_web/router\.ex$"E,
        ~r"lib/herdr_liveview_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  System.get_env("HERDR_LIVEVIEW_TOKEN") ||
    raise "environment variable HERDR_LIVEVIEW_TOKEN is missing"

  {:ok, ip} =
    System.get_env("HERDR_LIVEVIEW_IP", "127.0.0.1")
    |> String.to_charlist()
    |> :inet.parse_address()

  config :herdr_liveview, HerdrLiveViewWeb.Endpoint,
    url: [host: "localhost", scheme: "http"],
    http: [ip: ip],
    check_origin: :conn,
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :herdr_liveview, HerdrLiveViewWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :herdr_liveview, HerdrLiveViewWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
