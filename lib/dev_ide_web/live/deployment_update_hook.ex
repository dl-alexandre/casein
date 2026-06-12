defmodule DevIdeWeb.DeploymentUpdateHook do
  @moduledoc "LiveView on_mount hook: subscribes to deploy updates and tracks connections for graceful drain."

  import Phoenix.Component
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:update_available, false)
      |> assign(:update_commits_behind, 0)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(DevIde.PubSub, "deploy:updates")
      DevIDE.Deployment.Drain.track(self())
    end

    socket =
      attach_hook(socket, :deployment_update, :handle_info, fn
        {:update_available, _version, commits_behind}, socket ->
          {:cont,
           socket
           |> assign(:update_available, true)
           |> assign(:update_commits_behind, commits_behind)}

        _msg, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end
end
