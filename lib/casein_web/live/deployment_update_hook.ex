defmodule CaseinWeb.DeploymentUpdateHook do
  @moduledoc "LiveView on_mount hook: subscribes to deploy updates and tracks connections for graceful drain."

  import Phoenix.Component
  import Phoenix.LiveView

  alias Casein.Deployment.LastDeploy

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:update_available, false)
      |> assign(:update_commits_behind, 0)
      |> assign(:deploy_drift, nil)
      |> assign(:deploy_failure, nil)
      |> assign(:deploy_in_progress, nil)

    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Casein.PubSub, "deploy:updates")
        Casein.Deployment.Drain.track(self())
        apply_poller_status(socket)
      else
        socket
      end

    # No connect-time version comparison here on purpose. Whether a reconnected
    # client genuinely needs a hard reload is exactly what `static_changed?/1`
    # answers (true iff the JS/CSS digest changed) — the LiveViews already turn
    # that into an external redirect in mount. A git-revision string check would
    # over-fire on code-only deploys and, because the client's served version is
    # frozen until a full reload, would loop against the JS background-reconnect.
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

        {:deploy_failure, info}, socket ->
          {:halt,
           socket
           |> assign(:deploy_failure, info)
           |> assign(:deploy_in_progress, nil)}

        {:deploy_in_progress, info}, socket ->
          {:halt,
           socket
           |> assign(:deploy_in_progress, info)
           |> assign(:deploy_failure, nil)}

        :deploy_poller_clear, socket ->
          {:halt,
           socket
           |> assign(:deploy_failure, nil)
           |> assign(:deploy_in_progress, nil)}

        {:deploy_reconnect}, socket ->
          # The draining instance we're attached to has waited out its grace and
          # wants us gone. Do a background LiveSocket reconnect (silent for
          # code-only deploys) so the old node can drain and stop.
          {:halt, push_event(socket, "casein:deploy_reconnect", %{})}

        _msg, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end

  defp apply_poller_status(socket) do
    case LastDeploy.banner_status() do
      {:failed, info} ->
        assign(socket, deploy_failure: info, deploy_in_progress: nil)

      {:in_progress, info} ->
        assign(socket, deploy_in_progress: info, deploy_failure: nil)

      :idle ->
        assign(socket, deploy_failure: nil, deploy_in_progress: nil)
    end
  end
end
