defmodule Casein.Deployment.Capabilities do
  @moduledoc """
  Declares optional operator integrations available in this deployment.

  Core defaults to no operator integrations. A deployment overlay must opt into
  each integration explicitly through the validated operator configuration.
  """

  @spec configured() :: [atom()]
  def configured do
    Application.get_env(:casein, :deployment_capabilities, [])
  end

  @spec enabled?(atom()) :: boolean()
  def enabled?(capability), do: capability in configured()
end
