defmodule Casein.OriginTest do
  use ExUnit.Case, async: false

  alias Casein.Origin

  setup do
    previous_id = Application.get_env(:casein, :origin_id)
    previous_name = Application.get_env(:casein, :origin_display_name)
    previous_canonical = Application.get_env(:casein, :canonical_public_origin)
    previous_endpoint = Application.get_env(:casein, CaseinWeb.Endpoint)

    on_exit(fn ->
      restore(:origin_id, previous_id)
      restore(:origin_display_name, previous_name)
      restore(:canonical_public_origin, previous_canonical)
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
    assert Origin.display_name("https://casein.devbox.example") == "Devbox"
  end

  test "public descriptors infer their friendly name from the configured endpoint" do
    Application.put_env(:casein, CaseinWeb.Endpoint, url: [host: "casein.devbox.example"])

    assert Origin.public_descriptor().display_name == "Devbox"
  end

  test "managed public origin overrides request hosts and rejects legacy hosts" do
    Application.put_env(
      :casein,
      :canonical_public_origin,
      "https://CASEIN.devbox.milcgroup.com:443/"
    )

    assert Origin.canonical_base_url() == "https://casein.devbox.milcgroup.com"

    assert Origin.public_base_url("https://devide.devbox.milcgroup.com") ==
             "https://casein.devbox.milcgroup.com"

    assert :ok =
             Origin.authorize_request_base("https://CASEIN.devbox.milcgroup.com:443/")

    assert {:error, :origin_mismatch} =
             Origin.authorize_request_base("https://devide.devbox.milcgroup.com")
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)

  defp restore_endpoint(nil), do: Application.delete_env(:casein, CaseinWeb.Endpoint)
  defp restore_endpoint(value), do: Application.put_env(:casein, CaseinWeb.Endpoint, value)
end
