defmodule Casein.OriginTest do
  use ExUnit.Case, async: false

  alias Casein.Origin

  setup do
    previous_id = Application.get_env(:casein, :origin_id)
    previous_name = Application.get_env(:casein, :origin_display_name)
    previous_endpoint = Application.get_env(:casein, CaseinWeb.Endpoint)

    on_exit(fn ->
      restore(:origin_id, previous_id)
      restore(:origin_display_name, previous_name)
      restore_endpoint(previous_endpoint)
    end)

    :ok
  end

  test "identity is independent of reachable URL" do
    assert Origin.pairing_descriptor("http://192.168.1.20:4000").id ==
             Origin.pairing_descriptor("https://changed.example.test").id
  end

  test "managed identity and friendly name overrides are honored" do
    Application.put_env(:casein, :origin_id, "local-mac-1")
    Application.put_env(:casein, :origin_display_name, "Studio Mac")

    assert Origin.public_descriptor("https://elsewhere.test") == %{
             id: "local-mac-1",
             display_name: "Studio Mac"
           }
  end

  test "friendly defaults distinguish local and devbox origins" do
    assert Origin.display_name("http://my-mac.local:4000") == "Local Mac"
    assert Origin.display_name("https://devide.devbox.example") == "Devbox"
  end

  test "public descriptors infer their friendly name from the configured endpoint" do
    Application.put_env(:casein, CaseinWeb.Endpoint, url: [host: "devide.devbox.example"])

    assert Origin.public_descriptor().display_name == "Devbox"
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)

  defp restore_endpoint(nil), do: Application.delete_env(:casein, CaseinWeb.Endpoint)
  defp restore_endpoint(value), do: Application.put_env(:casein, CaseinWeb.Endpoint, value)
end
