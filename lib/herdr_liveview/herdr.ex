defmodule HerdrLiveView.Herdr do
  @moduledoc "Commands sent to the herdr server on behalf of the web UI."

  alias HerdrLiveView.Herdr.Client

  @keys ~w(enter esc tab up down left right ctrl+c ctrl+d)
  @max_prompt_bytes 64_000

  def allowed_keys, do: @keys

  def read_pane(pane_id) do
    params = %{pane_id: pane_id, source: "visible", format: "ansi", strip_ansi: false}

    with {:ok, %{"read" => %{"text" => text}}} <-
           Client.request("pane.read", params, timeout: 3_000) do
      {:ok, text}
    end
  end

  def prompt(pane_id, text) when is_binary(text) and byte_size(text) <= @max_prompt_bytes do
    Client.request("agent.prompt", %{target: pane_id, text: text})
  end

  def prompt(_pane_id, _text), do: {:error, :invalid_prompt}

  def send_key(pane_id, key) when key in @keys do
    Client.request("agent.send_keys", %{target: pane_id, keys: [key]})
  end

  def send_key(_pane_id, _key), do: {:error, :invalid_key}
end
