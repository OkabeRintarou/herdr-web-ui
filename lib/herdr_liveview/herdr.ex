defmodule HerdrLiveView.Herdr do
  @moduledoc "Commands sent to a host's herdr server on behalf of the web UI."

  alias HerdrLiveView.Herdr.Client

  @keys ~w(enter esc tab up down left right ctrl+c ctrl+d)
  @max_prompt_bytes 64_000

  def allowed_keys, do: @keys

  def read_pane(host, pane_id) do
    params = %{pane_id: pane_id, source: "visible", format: "ansi", strip_ansi: false}

    with {:ok, %{"read" => %{"text" => text}}} <-
           Client.request("pane.read", params, socket_path: host.socket_path, timeout: 3_000) do
      {:ok, text}
    end
  end

  def prompt(host, pane_id, text)
      when is_binary(text) and byte_size(text) <= @max_prompt_bytes do
    Client.request("agent.prompt", %{target: pane_id, text: text}, socket_path: host.socket_path)
  end

  def prompt(_host, _pane_id, _text), do: {:error, :invalid_prompt}

  def send_key(host, pane_id, key) when key in @keys do
    Client.request("agent.send_keys", %{target: pane_id, keys: [key]},
      socket_path: host.socket_path
    )
  end

  def send_key(_host, _pane_id, _key), do: {:error, :invalid_key}
end
