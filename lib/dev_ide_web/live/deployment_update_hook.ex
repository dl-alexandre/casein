defmodule DevIdeWeb.DeploymentUpdateHook do
  @moduledoc "LiveView on_mount hook: subscribes to deploy updates and tracks connections for graceful drain."

  import Phoenix.Component
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    socket = assign(socket, :update_available, false)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(DevIde.PubSub, "deploy:updates")
      DevIDE.Deployment.Drain.track(self())
    end

    socket =
      attach_hook(socket, :deployment_update, :handle_info, fn
        {:update_available, _version}, socket ->
          {:cont, assign(socket, :update_available, true)}

        _msg, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end
end
