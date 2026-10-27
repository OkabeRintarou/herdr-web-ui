defmodule HerdrLiveViewWeb.AuthTest do
  use HerdrLiveViewWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    Application.put_env(:herdr_liveview, :access_token, "s3cret")
    on_exit(fn -> Application.put_env(:herdr_liveview, :access_token, nil) end)
  end

  test "rejects requests without a valid token", %{conn: conn} do
    assert conn |> get(~p"/") |> response(401)
    assert build_conn() |> get(~p"/?token=wrong") |> response(401)
  end

  test "a valid token is exchanged for a session and stripped from the URL", %{conn: conn} do
    conn = get(conn, ~p"/?token=s3cret")
    assert redirected_to(conn) == ~p"/"

    conn = conn |> recycle() |> get(~p"/")
    assert html_response(conn, 200)

    assert {:ok, _view, _html} = live(conn, ~p"/")
  end
end
