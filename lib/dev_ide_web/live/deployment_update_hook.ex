defmodule DevIdeWeb.DeploymentUpdateHook do
  @moduledoc "LiveView on_mount hook: subscribes to deploy updates and tracks connections for graceful drain."

  import Phoenix.Component
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:update_available, false)
      |> assign(:update_commits_behind, 0)
      |> assign(:deploy_drift, nil)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(DevIde.PubSub, "deploy:updates")
      DevIDE.Deployment.Drain.track(self())
    end

    socket =
      attach_hook(socket, :deployment_update, :handle_info, fn
        {:update_available, _version, commits_behind}, socket ->
          {:halt,
           socket
           |> assign(:update_available, true)
           |> assign(:update_commits_behind, commits_behind)}

        {:update_available, _version}, socket ->
          {:halt, assign(socket, :update_available, true)}

        {:deploy_drift, info}, socket ->
          {:halt, assign(socket, :deploy_drift, info)}

        _msg, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end
end
