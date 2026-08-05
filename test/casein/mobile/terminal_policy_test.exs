defmodule Casein.Mobile.TerminalPolicyTest do
  use ExUnit.Case, async: false

  alias Casein.Mobile.TerminalPolicy

  @context %{
    user_id: "user-1",
    device_link_id: "device-1",
    workspace_id: "workspace-1"
  }

  setup do
    previous = Application.get_env(:casein, :mobile_terminal)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:casein, :mobile_terminal),
        else: Application.put_env(:casein, :mobile_terminal, previous)
    end)

    :ok
  end

  test "defaults fail closed when configuration is absent" do
    Application.delete_env(:casein, :mobile_terminal)

    assert {:error, :kill_switch_active} = TerminalPolicy.authorize(@context)
    refute TerminalPolicy.enabled_for?(@context)
    assert TerminalPolicy.kill_switch_active?()
  end

  test "kill switch wins over enabled deployment and exact allowlists" do
    configure(enabled: true, kill_switch: true)

    assert {:error, :kill_switch_active} = TerminalPolicy.authorize(@context)
  end

  test "deployment flag is required after kill switch is released" do
    configure(enabled: false, kill_switch: false)

    assert {:error, :feature_disabled} = TerminalPolicy.authorize(@context)
  end

  test "all three exact rollout dimensions are required" do
    configure(enabled: true, kill_switch: false, user_ids: [])
    assert {:error, :user_not_allowlisted} = TerminalPolicy.authorize(@context)

    configure(enabled: true, kill_switch: false, device_link_ids: [])
    assert {:error, :device_not_allowlisted} = TerminalPolicy.authorize(@context)

    configure(enabled: true, kill_switch: false, workspace_ids: [])
    assert {:error, :workspace_not_allowlisted} = TerminalPolicy.authorize(@context)
  end

  test "exact allowlist match admits only the requested tuple" do
    configure(enabled: true, kill_switch: false)

    assert :ok = TerminalPolicy.authorize(@context)
    assert TerminalPolicy.enabled_for?(@context)

    refute TerminalPolicy.enabled_for?(%{@context | workspace_id: "workspace-2"})
    refute TerminalPolicy.enabled_for?(%{@context | device_link_id: "device-2"})
    refute TerminalPolicy.enabled_for?(%{@context | user_id: "user-2"})
  end

  test "missing or malformed identity fails closed" do
    configure(enabled: true, kill_switch: false)

    assert {:error, :invalid_context} = TerminalPolicy.authorize(%{})
    assert {:error, :invalid_context} = TerminalPolicy.authorize(nil)
    assert {:error, :invalid_context} = TerminalPolicy.authorize(%{@context | user_id: ""})
  end

  test "malformed deployment configuration fails closed" do
    Application.put_env(:casein, :mobile_terminal, %{enabled: true, kill_switch: false})

    assert {:error, :kill_switch_active} = TerminalPolicy.authorize(@context)
    assert TerminalPolicy.kill_switch_active?()
  end

  defp configure(overrides) do
    defaults = [
      enabled: false,
      kill_switch: true,
      user_ids: [@context.user_id],
      device_link_ids: [@context.device_link_id],
      workspace_ids: [@context.workspace_id]
    ]

    Application.put_env(:casein, :mobile_terminal, Keyword.merge(defaults, overrides))
  end
end
