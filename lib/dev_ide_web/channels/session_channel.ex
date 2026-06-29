defmodule DevIdeWeb.SessionChannel do
  @moduledoc """
  Mobile companion channel (v1a) — a live, read-only projection of one
  workspace's supervisory state. Topic: `session:<workspace_id>`.

  This is the "ACP as façade" surface: it owns no session state. It joins on
  a `DevIDE.Session.Snapshot`, subscribes to the three event spines the
  runtime already broadcasts, and pushes a fresh snapshot (debounced) whenever
  something supervisory changes:

    * `DevIDE.Audit` (`{:audit_event, _}`)            — runs, policy decisions, ledger
    * `DevIDE.Workspaces.State` (`{:workspace_mode_changed, _, _}`)
    * `DevIDE.Agents.Activity` (`{:agent_mcp_activity, _}`)

  Write affordances are deliberately *not* here in v1a. The only action a
  client may take is read/refresh; quick allowlisted commands and approvals
  (v1b) route through the existing policy gate, not a mobile-specific path.

  Auth reuses `UserSocket` (`current_user` is already assigned on connect);
  join additionally checks workspace membership before exposing any state.
  """

  use Phoenix.Channel

  alias DevIDE.Audit
  alias DevIDE.Agents.Activity
  alias DevIDE.Alerts
  alias DevIDE.Mobile.UserObserver
  alias DevIDE.Push
  alias DevIDE.Session.Snapshot
  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.State

  # Coalesce bursts of deltas into one push.
  @debounce_ms 150

  @impl true
  def join("session:" <> workspace_id, _params, socket) do
    user = socket.assigns[:current_user] || %{}

    case authorize_join(socket, user, workspace_id) do
      :ok ->
        :ok = Audit.subscribe(workspace_id)
        :ok = Activity.subscribe(workspace_id)
        _ = State.subscribe_mode_changes(workspace_id)
        observe_mobile_workspace(socket, workspace_id)

        socket =
          socket
          |> assign(:workspace_id, workspace_id)
          |> assign(:refresh_timer, nil)

        {:ok, render(Snapshot.build(workspace_id)), socket}

      {:error, reason} ->
        report_mobile_connection_issue(socket, workspace_id, reason)
        {:error, %{reason: Atom.to_string(reason)}}
    end
  end

  # Explicit pull-to-refresh from the client.
  @impl true
  def handle_in("refresh", _params, socket) do
    push(socket, "snapshot", render(Snapshot.build(socket.assigns.workspace_id)))
    {:noreply, socket}
  end

  # Register an OS push token for this workspace. Authorization already happened
  # at join (owner/admin), so a token registered here is only ever pushed for a
  # workspace this identity may observe. `platform` stays a string — never
  # atomized (untrusted input).
  def handle_in("register_push", %{"token" => token, "platform" => platform}, socket)
      when is_binary(token) and is_binary(platform) do
    user = socket.assigns[:current_user] || %{}

    case Push.ready_for?(platform) do
      :ok ->
        Push.register(%{
          workspace_id: socket.assigns.workspace_id,
          token: token,
          platform: platform,
          user_id: user[:id]
        })

        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason_to_string(reason)}}, socket}
    end
  end

  def handle_in("unregister_push", %{"token" => token}, socket) when is_binary(token) do
    Push.unregister(token)
    {:reply, :ok, socket}
  end

  def handle_in(_event, _params, socket), do: {:noreply, socket}

  # Any supervisory delta → schedule a single debounced rebuild. Alert-worthy
  # actions also fire a discrete (non-debounced) "alert" so the client can
  # notify promptly rather than waiting on the coalesced snapshot.
  @impl true
  def handle_info({:audit_event, event}, socket) do
    maybe_push_alert(socket, event)
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info({:agent_mcp_activity, _entry}, socket), do: {:noreply, schedule_refresh(socket)}

  def handle_info({:workspace_mode_changed, _id, _mode}, socket),
    do: {:noreply, schedule_refresh(socket)}

  def handle_info(:do_refresh, socket) do
    push(socket, "snapshot", render(Snapshot.build(socket.assigns.workspace_id)))
    {:noreply, assign(socket, :refresh_timer, nil)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp schedule_refresh(%{assigns: %{refresh_timer: ref}} = socket) when is_reference(ref) do
    # A rebuild is already pending; let it coalesce this delta.
    socket
  end

  defp schedule_refresh(socket) do
    ref = Process.send_after(self(), :do_refresh, @debounce_ms)
    assign(socket, :refresh_timer, ref)
  end

  # --- authorization -------------------------------------------------------

  # The companion exposes one workspace's supervisory state, so observation
  # demands the same ownership the terminal channel already requires for raw
  # PTY access: `Workspaces.viewer_terminal_owner?/2` (admin OR owns the
  # workspace, matched across id/username/email). This is deliberately
  # stricter than the policy-default `:viewer` role — that default is "anyone
  # authenticated," which would leak every workspace's runs to every user.
  defp authorize_join(socket, user, workspace_id) when is_binary(workspace_id) do
    cond do
      not scoped_to_topic?(socket, workspace_id) ->
        {:error, :workspace_scope_mismatch}

      true ->
        case Workspaces.get(workspace_id) do
          {:ok, workspace} ->
            if Workspaces.viewer_terminal_owner?(workspace, user),
              do: :ok,
              else: {:error, :unauthorized}

          {:error, reason} ->
            if workspace_missing?(reason),
              do: {:error, :workspace_not_found},
              else: {:error, :workspace_unavailable}
        end
    end
  end

  defp scoped_to_topic?(socket, workspace_id) do
    case socket.assigns[:pairing_workspace_id] do
      nil -> true
      ^workspace_id -> true
      _other -> false
    end
  end

  defp workspace_missing?(:not_found), do: true
  defp workspace_missing?({:http, status, _body}) when status in [404, 410], do: true
  defp workspace_missing?(_reason), do: false

  defp observe_mobile_workspace(socket, workspace_id) do
    with user_id when is_binary(user_id) <- current_user_id(socket) do
      _ = UserObserver.watch_workspace(user_id, workspace_id)
      _ = UserObserver.connection_live(user_id, workspace_id)
    end

    :ok
  end

  defp report_mobile_connection_issue(socket, workspace_id, reason) do
    with user_id when is_binary(user_id) <- current_user_id(socket) do
      UserObserver.connection_issue_changed(user_id, %{
        workspace_id: workspace_id,
        reason: connection_issue_reason(reason),
        last_seen_at: DateTime.utc_now()
      })
    end

    :ok
  end

  defp current_user_id(socket) do
    user = socket.assigns[:current_user] || %{}
    Map.get(user, :id) || Map.get(user, "id")
  end

  defp connection_issue_reason(:workspace_unavailable), do: :offline
  defp connection_issue_reason(:workspace_scope_mismatch), do: :token_revoked
  defp connection_issue_reason(:unauthorized), do: :token_revoked
  defp connection_issue_reason(_reason), do: :join_failed

  defp maybe_push_alert(socket, event) do
    case Alerts.notification_for(event) do
      nil -> :ok
      notification -> push(socket, "alert", notification)
    end
  end

  # --- wire shape (mobile renders cards from this) -------------------------

  defp render(%Snapshot{} = s) do
    %{
      workspace_id: s.workspace_id,
      mode: s.mode,
      mode_source: s.mode_source,
      current_run: s.current_run,
      recent_runs: s.recent_runs,
      last_decision: render_decision(s.last_decision),
      recent_audit: Enum.map(s.recent_audit, &render_audit/1),
      active_agents: Enum.map(s.active_agents, &render_agent/1),
      pending_reviews: s.pending_reviews,
      updated_at: s.updated_at
    }
  end

  defp render_decision(nil), do: nil

  defp render_decision(d) do
    %{action: d.action, decision: d.decision, reason: to_wire(d.reason), mode: d.mode, at: d.at}
  end

  defp render_audit(row) do
    %{
      action: row.action,
      decision: row.decision,
      reason: to_wire(row.reason),
      target_ref: row.target_ref,
      at: row.at
    }
  end

  defp render_agent(entry) do
    %{
      tool: entry.tool,
      summary: entry.summary,
      status: entry.status,
      source: entry.source,
      at: entry.inserted_at
    }
  end

  defp to_wire(nil), do: nil
  defp to_wire(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp to_wire(other), do: other

  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason) when is_binary(reason), do: reason
  defp reason_to_string(reason), do: inspect(reason)
end
