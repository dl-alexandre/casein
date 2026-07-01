defmodule DevIdeWeb.DeploymentUpdateHook do
  @moduledoc "LiveView on_mount hook: subscribes to deploy updates and tracks connections for graceful drain."

  import Phoenix.Component
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:update_available, false)
      |> assign(:update_commits_behind, 0)
      |> assign(:update_reason, nil)
      |> assign(:deploy_drift, nil)

    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(DevIde.PubSub, "deploy:updates")
        DevIDE.Deployment.Drain.track(self())
        maybe_flag_version_mismatch(socket)
      else
        socket
      end

    socket =
      attach_hook(socket, :deployment_update, :handle_info, fn
        {:update_available, _version, commits_behind}, socket ->
          {:halt,
           socket
           |> assign(:update_available, true)
           |> assign(:update_reason, :deploy)
           |> assign(:update_commits_behind, commits_behind)}

        {:update_available, _version}, socket ->
          {:halt,
           socket
           |> assign(:update_available, true)
           |> assign(:update_reason, :deploy)}

        {:deploy_drift, info}, socket ->
          {:halt, assign(socket, :deploy_drift, info)}

        _msg, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end

  # Passive safety net: the browser reports the version it was served with via a
  # connect param. If this instance is running a different revision, the client
  # reconnected onto a newer release (e.g. the old instance died before it could
  # broadcast its drain, or the user was glued to a terminal past the drain
  # timeout) — flag the banner so it eventually reloads. Complements the
  # push-from-draining-instance path; does not replace it.
  defp maybe_flag_version_mismatch(socket) do
    client_version = (get_connect_params(socket) || %{})["client_version"]
    server_version = DevIDE.Deployment.Version.version()

    if is_binary(client_version) and client_version not in ["", "unknown"] and
         client_version != server_version do
      socket
      |> assign(:update_available, true)
      |> assign(:update_reason, :version_mismatch)
    else
      socket
    end
  end
end
