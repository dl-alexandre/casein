defmodule Casein.Access.EndpointsTest do
  use ExUnit.Case, async: false

  alias Casein.Access.Endpoint
  alias Casein.Access.Endpoints

  setup do
    previous_canonical = Application.get_env(:casein, :canonical_public_origin)
    previous_endpoint = Application.get_env(:casein, CaseinWeb.Endpoint)

    previous_env =
      snapshot_env(
        ~w(CASEIN_LAN_HOST CASEIN_LAN_IP CASEIN_LAN CASEIN_LAN_INSECURE_HTTP CASEIN_LAN_INSECURE_HTTP_PORT PORT)
      )

    on_exit(fn ->
      restore(:canonical_public_origin, previous_canonical)
      restore_endpoint(previous_endpoint)
      restore_env(previous_env)
    end)

    clear_lan_env()
    :ok
  end

  test "advertised/0 returns quickly with no LAN config and no network I/O" do
    Application.put_env(:casein, :canonical_public_origin, nil)
    Application.put_env(:casein, CaseinWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: 4002])

    started = System.monotonic_time(:millisecond)
    endpoints = Endpoints.advertised()
    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < 200
    assert Enum.any?(endpoints, &(&1.kind == :loopback))
    refute Enum.any?(endpoints, &(&1.kind == :lan))
    refute Enum.any?(endpoints, &(&1.kind == :public_https))
  end

  test "advertised/0 includes public and LAN from existing config keys" do
    Application.put_env(:casein, :canonical_public_origin, "https://casein.devbox.example/")
    Application.put_env(:casein, CaseinWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: 4002])
    System.put_env("CASEIN_LAN_HOST", "studio.local")
    System.put_env("CASEIN_LAN_INSECURE_HTTP_PORT", "80")

    endpoints = Endpoints.advertised()
    kinds = Enum.map(endpoints, & &1.kind)

    assert :loopback in kinds
    assert :public_https in kinds
    assert :lan in kinds

    public = Enum.find(endpoints, &(&1.kind == :public_https))
    assert public.base_url == "https://casein.devbox.example"
    assert public.scope == :any

    lan = Enum.find(endpoints, &(&1.kind == :lan))
    assert lan.base_url == "http://studio.local"
    assert lan.scope == :same_lan
  end

  test "doctor_lines/1 shapes endpoint + probe output" do
    lines =
      Endpoints.doctor_lines([
        {Endpoint.loopback("http://127.0.0.1:4000"), true},
        {Endpoint.public_https("https://casein.example.com"), false}
      ])

    assert Enum.at(lines, 0) == "Access endpoints"
    assert Enum.any?(lines, &String.contains?(&1, "loopback"))
    assert Enum.any?(lines, &String.contains?(&1, "alive"))
    assert Enum.any?(lines, &String.contains?(&1, "dead"))
  end

  defp snapshot_env(names) do
    Map.new(names, fn name -> {name, System.get_env(name)} end)
  end

  defp restore_env(env) do
    Enum.each(env, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end

  defp clear_lan_env do
    Enum.each(
      ~w(CASEIN_LAN_HOST CASEIN_LAN_IP CASEIN_LAN CASEIN_LAN_INSECURE_HTTP CASEIN_LAN_INSECURE_HTTP_PORT),
      &System.delete_env/1
    )
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)

  defp restore_endpoint(nil), do: Application.delete_env(:casein, CaseinWeb.Endpoint)
  defp restore_endpoint(value), do: Application.put_env(:casein, CaseinWeb.Endpoint, value)
end
