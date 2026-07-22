defmodule DevIDE.Deployment.CapabilitiesTest do
  use ExUnit.Case, async: false

  alias DevIDE.Deployment.Capabilities

  setup do
    previous = Application.get_env(:dev_ide, :deployment_capabilities)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:dev_ide, :deployment_capabilities)
      else
        Application.put_env(:dev_ide, :deployment_capabilities, previous)
      end
    end)
  end

  test "portable profiles can disable every operator integration" do
    Application.put_env(:dev_ide, :deployment_capabilities, [])

    refute Capabilities.enabled?(:deploy_drift)
    refute Capabilities.enabled?(:deploy_status)
    refute Capabilities.enabled?(:poller)
    refute Capabilities.enabled?(:reverse_proxy)
    refute Capabilities.enabled?(:socket)
  end

  test "core defaults to no operator integrations" do
    Application.delete_env(:dev_ide, :deployment_capabilities)

    assert Capabilities.configured() == []
  end

  test "configured integrations are explicit" do
    Application.put_env(:dev_ide, :deployment_capabilities, [:deploy_drift])

    assert Capabilities.enabled?(:deploy_drift)
    refute Capabilities.enabled?(:poller)
  end
end
