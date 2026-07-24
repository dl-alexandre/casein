defmodule CaseinWeb.WorkspaceLive.Show.WorkspacePolicyEvents do
  # Workspace lifecycle and policy handle_event clauses extracted verbatim from
  # CaseinWeb.WorkspaceLive.Show (pure code motion — no behavior change).
  # Show delegates every "workspace:*" event here.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView
  import CaseinWeb.WorkspaceLive.Show.Context

  alias Casein.{Audit, Policy, Workspaces}
  alias Casein.Policy.Decision
  alias CaseinWeb.WorkspaceLive.Show

  @agent_write_unlock_min_minutes 5
  @agent_write_unlock_max_minutes 240

  def handle_event("workspace:start", _params, socket) do
    case Workspaces.start(socket.assigns.workspace.id, current_user_email(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:workspace_start_error, nil)
         |> refresh_workspace_assign()
         |> put_flash(:info, "Workspace start requested. Retry the terminal once it is running.")}

      {:error, reason} ->
        message = format_workspace_action_error(reason)

        {:noreply,
         socket
         |> assign(:workspace_start_error, message)
         |> put_flash(:error, "Could not start workspace: #{message}")}
    end
  end

  def handle_event("workspace:stop", _params, socket) do
    case Workspaces.stop(socket.assigns.workspace.id, current_user_email(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_workspace_assign()
         |> put_flash(:info, "Workspace stop requested.")}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Could not stop workspace: #{format_workspace_action_error(reason)}"
         )}
    end
  end

  def handle_event("workspace:set_mode", %{"mode" => mode_str}, socket) do
    mode = string_to_mode(mode_str)

    {decision, socket} =
      gate(socket, fn -> Policy.can_set_workspace_mode?(policy_ctx(socket)) end, %{
        action: "workspace.set_mode",
        target_type: "workspace",
        target_ref: socket.assigns.workspace.id,
        metadata: %{"requested_mode" => mode_str}
      })

    cond do
      not Decision.allow?(decision) ->
        {:noreply, put_flash(socket, :error, mode_change_denied_message(decision))}

      mode == nil ->
        {:noreply, socket}

      true ->
        ws_id = socket.assigns.workspace.id
        {_, _} = Workspaces.set_mode(ws_id, mode)

        _ =
          Audit.emit!(%{
            action: "workspace.mode_changed",
            workspace_id: ws_id,
            actor_id: current_actor_id(socket),
            target_type: "workspace",
            target_ref: ws_id,
            metadata: %{"mode" => Atom.to_string(mode)}
          })

        {:noreply,
         socket
         |> Show.assign_workspace_mode(ws_id, connected?(socket))
         |> Show.refresh_terminal_workspace_capability()
         |> Show.maybe_schedule_raw_prewarm()}
    end
  end

  def handle_event("workspace:grant_agent_write_unlock", %{"minutes" => minutes_str}, socket) do
    minutes = clamp_unlock_minutes(minutes_str)

    {decision, socket} =
      gate(socket, fn -> Policy.can_grant_agent_write_unlock?(policy_ctx(socket)) end, %{
        action: "workspace.agent_write_unlock_grant_attempt",
        target_type: "workspace",
        target_ref: socket.assigns.workspace.id,
        metadata: %{"requested_minutes" => minutes}
      })

    if Decision.allow?(decision) do
      ws_id = socket.assigns.workspace.id
      granter = current_actor_id(socket)
      until = DateTime.add(DateTime.utc_now(), minutes * 60, :second)
      {:ok, _} = Workspaces.grant_agent_write_unlock(ws_id, until, granter)

      _ =
        Audit.emit!(%{
          action: "workspace.agent_write_unlock_granted",
          workspace_id: ws_id,
          actor_id: granter,
          target_type: "workspace",
          target_ref: ws_id,
          metadata: %{"until" => DateTime.to_iso8601(until), "minutes" => minutes}
        })

      {:noreply,
       socket
       |> Show.assign_agent_write_unlock(ws_id)
       |> put_flash(:info, "Agent write unlocked for #{minutes} min.")}
    else
      {:noreply, put_flash(socket, :error, agent_write_unlock_denied_message(decision))}
    end
  end

  def handle_event("workspace:revoke_agent_write_unlock", _params, socket) do
    {decision, socket} =
      gate(socket, fn -> Policy.can_revoke_agent_write_unlock?(policy_ctx(socket)) end, %{
        action: "workspace.agent_write_unlock_revoke_attempt",
        target_type: "workspace",
        target_ref: socket.assigns.workspace.id
      })

    if Decision.allow?(decision) do
      ws_id = socket.assigns.workspace.id
      {:ok, _} = Workspaces.revoke_agent_write_unlock(ws_id)

      _ =
        Audit.emit!(%{
          action: "workspace.agent_write_unlock_revoked",
          workspace_id: ws_id,
          actor_id: current_actor_id(socket),
          target_type: "workspace",
          target_ref: ws_id
        })

      {:noreply, socket |> Show.assign_agent_write_unlock(ws_id) |> put_flash(:info, "Revoked.")}
    else
      {:noreply, put_flash(socket, :error, "Not allowed to revoke.")}
    end
  end

  defp current_user_email(socket), do: socket.assigns.current_user[:email]

  defp refresh_workspace_assign(socket) do
    case Workspaces.get(socket.assigns.workspace.id, current_user_email(socket)) do
      {:ok, workspace} -> assign(socket, :workspace, workspace)
      {:error, _reason} -> socket
    end
  end

  defp format_workspace_action_error({:http, _status, body}),
    do: format_workspace_action_error(body)

  defp format_workspace_action_error(%{"error" => message}) when is_binary(message), do: message

  defp format_workspace_action_error(%{error: message}) when is_binary(message), do: message

  defp format_workspace_action_error(reason), do: inspect(reason)

  defp string_to_mode("manual"), do: :manual
  defp string_to_mode("review"), do: :review
  defp string_to_mode("agent_write_locked"), do: :agent_write_locked
  defp string_to_mode("shared_stage_guarded"), do: :shared_stage_guarded
  defp string_to_mode(_), do: nil

  defp mode_change_denied_message(%Decision{reason: :config_override}),
    do: "Workspace mode is pinned by configuration."

  defp mode_change_denied_message(%Decision{reason: :forbidden}),
    do: "Only the workspace owner can change mode."

  defp mode_change_denied_message(%Decision{reason: reason}) when not is_nil(reason),
    do: "Cannot change mode: #{reason |> Atom.to_string() |> String.replace("_", " ")}"

  defp mode_change_denied_message(_), do: "Cannot change workspace mode."

  defp agent_write_unlock_denied_message(%Decision{reason: :config_override}),
    do: "Workspace mode is pinned by configuration."

  defp agent_write_unlock_denied_message(%Decision{reason: :forbidden}),
    do: "Only the workspace owner can grant agent write."

  defp agent_write_unlock_denied_message(%Decision{reason: :requires_manual_mode}),
    do: "Agent write unlock requires manual mode."

  defp agent_write_unlock_denied_message(%Decision{reason: reason}) when not is_nil(reason),
    do: "Cannot unlock agent write: #{reason |> Atom.to_string() |> String.replace("_", " ")}"

  defp agent_write_unlock_denied_message(_), do: "Cannot unlock agent write."

  defp clamp_unlock_minutes(minutes_str) do
    case Integer.parse(to_string(minutes_str)) do
      {n, _} -> n |> max(@agent_write_unlock_min_minutes) |> min(@agent_write_unlock_max_minutes)
      :error -> @agent_write_unlock_min_minutes
    end
  end
end
