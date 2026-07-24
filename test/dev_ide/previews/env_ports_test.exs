defmodule Casein.Previews.EnvPortsTest do
  use Casein.TestCase, async: false

  alias Casein.Previews.EnvPorts

  setup do
    prev_range = Application.get_env(:dev_ide, :preview_env_port_range)
    prev_runtime_range = Application.get_env(:dev_ide, :runtime_preview_port_range)
    prev_router_port = Application.get_env(:dev_ide, :preview_router_port)
    prev_router_admin_port = Application.get_env(:dev_ide, :preview_router_admin_port)
    prev_loopback = Application.get_env(:dev_ide, :preview_loopback_port)
    prev_port = System.get_env("PORT")

    on_exit(fn ->
      restore_env(:preview_env_port_range, prev_range)
      restore_env(:runtime_preview_port_range, prev_runtime_range)
      restore_env(:preview_router_port, prev_router_port)
      restore_env(:preview_router_admin_port, prev_router_admin_port)
      restore_env(:preview_loopback_port, prev_loopback)

      if prev_port,
        do: System.put_env("PORT", prev_port),
        else: System.delete_env("PORT")
    end)

    :ok
  end

  test "port_range reads configured inclusive bounds" do
    Application.put_env(:dev_ide, :preview_env_port_range, {41_010, 41_020})
    assert EnvPorts.port_range() == {41_010, 41_020}
  end

  test "port_range falls back when config is invalid" do
    Application.put_env(:dev_ide, :preview_env_port_range, :invalid)
    assert EnvPorts.port_range() == {41_000, 41_049}
  end

  test "preview_env_port? is true inside the ephemeral range" do
    assert EnvPorts.preview_env_port?(41_000)
    assert EnvPorts.preview_env_port?(41_049)
    refute EnvPorts.preview_env_port?(40_999)
    refute EnvPorts.preview_env_port?(41_050)
    refute EnvPorts.preview_env_port?("41000")
  end

  test "runtime_port_range reads configured inclusive bounds" do
    Application.put_env(:dev_ide, :runtime_preview_port_range, {41_050, 41_079})
    assert EnvPorts.runtime_port_range() == {41_050, 41_079}
  end

  test "runtime_port_range falls back when config is invalid" do
    Application.put_env(:dev_ide, :runtime_preview_port_range, :invalid)
    assert EnvPorts.runtime_port_range() == {41_050, 41_079}
  end

  test "runtime_preview_port? is true inside the runtime preview range" do
    assert EnvPorts.runtime_preview_port?(41_050)
    assert EnvPorts.runtime_preview_port?(41_079)
    refute EnvPorts.runtime_preview_port?(41_049)
    refute EnvPorts.runtime_preview_port?(41_080)
    refute EnvPorts.runtime_preview_port?("41050")
  end

  test "router ports default to the infrastructure band" do
    assert EnvPorts.router_port() == 41_080
    assert EnvPorts.router_admin_port() == 41_081

    Application.put_env(:dev_ide, :preview_router_port, 41_090)
    Application.put_env(:dev_ide, :preview_router_admin_port, 41_091)

    assert EnvPorts.router_port() == 41_090
    assert EnvPorts.router_admin_port() == 41_091
  end

  test "current_port prefers preview_loopback_port then PORT env" do
    Application.put_env(:dev_ide, :preview_loopback_port, 41_055)
    assert EnvPorts.current_port() == 41_055

    Application.delete_env(:dev_ide, :preview_loopback_port)
    System.put_env("PORT", "4123")
    assert EnvPorts.current_port() == 4123
  end

  test "preview_env_instance? reflects whether current port is ephemeral" do
    Application.put_env(:dev_ide, :preview_loopback_port, 41_042)
    assert EnvPorts.preview_env_instance?()

    Application.put_env(:dev_ide, :preview_loopback_port, 4000)
    refute EnvPorts.preview_env_instance?()
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
