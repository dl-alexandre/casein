defmodule DevIDE.Deployment.Capabilities do
  @moduledoc """
  Declares optional operator integrations available in this deployment.

  Portable profiles explicitly configure an empty or narrow capability set.
  The legacy defaults remain temporarily for existing devbox installations
  until their configuration moves into the private operator overlay.
  """

  @legacy_defaults [:socket, :reverse_proxy, :deploy_drift, :deploy_status, :poller]

  @spec configured() :: [atom()]
  def configured do
    Application.get_env(:dev_ide, :deployment_capabilities, @legacy_defaults)
  end

  @spec enabled?(atom()) :: boolean()
  def enabled?(capability), do: capability in configured()
end
