defmodule HerdrLiveViewWeb.Auth do
  @moduledoc """
  Shared-token access control. Visiting any page with `?token=...` once stores
  an authenticated flag in the session cookie. Disabled when no token is configured.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    case expected_token() do
      nil ->
        conn

      expected ->
        cond do
          valid?(conn.query_params["token"], expected) ->
            conn
            |> configure_session(renew: true)
            |> put_session(:herdr_authed, true)
            |> redirect(to: conn.request_path)
            |> halt()

          get_session(conn, :herdr_authed) ->
            conn

          true ->
            conn
            |> put_resp_content_type("text/plain")
            |> send_resp(401, "unauthorized: open the URL printed by the plugin status action\n")
            |> halt()
        end
    end
  end

  def on_mount(:require_auth, _params, session, socket) do
    if expected_token() == nil or session["herdr_authed"] do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    end
  end

  defp expected_token, do: Application.get_env(:herdr_liveview, :access_token)

  defp valid?(given, expected) when is_binary(given),
    do: Plug.Crypto.secure_compare(given, expected)

  defp valid?(_given, _expected), do: false
end
