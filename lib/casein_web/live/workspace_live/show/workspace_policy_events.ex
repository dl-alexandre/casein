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
end
