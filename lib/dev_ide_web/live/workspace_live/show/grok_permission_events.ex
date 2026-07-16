defmodule DevIdeWeb.WorkspaceLive.Show.GrokPermissionEvents do
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3]

  alias DevIDE.AgentSessions.GrokACP.Attachments
  alias DevIDE.Audit
  alias DevIdeWeb.WorkspaceLive.Show.Context

  @doc "Seeds and subscribes the workspace-global permission surface."
  def mount(socket) do
    socket = assign(socket, :grok_permission_requests, [])

    if connected?(socket) do
      workspace_id = socket.assigns.workspace.id
      :ok = Attachments.subscribe(workspace_id)
      refresh(socket)
    else
      socket
    end
  end

  @doc "Applies a workspace-scoped attachment update pushed by the manager."
  def handle_info(
        {:grok_acp_attachments_updated, workspace_id, snapshots},
        %{assigns: %{workspace: %{id: workspace_id}}} = socket
      )
      when is_list(snapshots) do
    assign(socket, :grok_permission_requests, normalize_requests(snapshots))
  end

  def handle_info({:grok_acp_attachments_updated, _workspace_id, _snapshots}, socket), do: socket

  def handle_event(
        "grok_permission:respond",
        %{
          "attachment-key" => attachment_key,
          "request-id" => request_id,
          "option-id" => option_id
        },
        socket
      )
      when is_binary(attachment_key) and attachment_key != "" and is_binary(request_id) and
             request_id != "" and is_binary(option_id) and option_id != "" do
    workspace_id = socket.assigns.workspace.id

    case manager_call(fn ->
           Attachments.respond_permission(workspace_id, attachment_key, request_id, option_id)
         end) do
      :ok ->
        record_decision(socket, attachment_key, request_id, "selected", option_id)

        {:noreply,
         socket
         |> refresh()
         |> put_flash(:info, "Permission response sent to Grok.")}

      {:error, reason} ->
        {:noreply, decision_error(socket, reason)}
    end
  end

  def handle_event(
        "grok_permission:cancel",
        %{"attachment-key" => attachment_key, "request-id" => request_id},
        socket
      )
      when is_binary(attachment_key) and attachment_key != "" and is_binary(request_id) and
             request_id != "" do
    workspace_id = socket.assigns.workspace.id

    case manager_call(fn ->
           Attachments.cancel_permission(workspace_id, attachment_key, request_id)
         end) do
      :ok ->
        record_decision(socket, attachment_key, request_id, "cancelled", nil)

        {:noreply,
         socket
         |> refresh()
         |> put_flash(:info, "Permission denied.")}

      {:error, reason} ->
        {:noreply, decision_error(socket, reason)}
    end
  end

  def handle_event("grok_permission:" <> _event, _params, socket) do
    {:noreply, put_flash(socket, :error, "That permission response was invalid.")}
  end

  defp refresh(socket) do
    requests =
      socket.assigns.workspace.id
      |> Attachments.list()
      |> normalize_requests()

    assign(socket, :grok_permission_requests, requests)
  catch
    :exit, _reason -> assign(socket, :grok_permission_requests, [])
  end

  defp decision_error(socket, reason) when reason in [:not_found, :permission_not_found] do
    socket
    |> refresh()
    |> put_flash(:info, "That request was already resolved.")
  end

  defp decision_error(socket, :invalid_option) do
    socket
    |> refresh()
    |> put_flash(:error, "Grok no longer offers that response.")
  end

  defp decision_error(socket, _reason) do
    socket
    |> refresh()
    |> put_flash(:error, "Grok could not accept that response.")
  end

  defp manager_call(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :manager_unavailable}
  end

  defp record_decision(socket, attachment_key, request_id, outcome, option_id) do
    metadata = %{
      source: "grok_acp",
      attachment_key: attachment_key,
      request_id: request_id,
      outcome: outcome
    }

    metadata = if option_id, do: Map.put(metadata, :option_id, option_id), else: metadata

    Audit.emit!(%{
      action: "agent.permission_decided",
      workspace_id: socket.assigns.workspace.id,
      actor_id: Context.current_actor_id(socket),
      target_type: "agent_permission",
      target_ref: attachment_key <> ":" <> request_id,
      metadata: metadata
    })
  end

  defp normalize_requests(snapshots) do
    Enum.flat_map(snapshots, fn snapshot ->
      attachment_key = value(snapshot, :attachment_key)
      session_id = value(snapshot, :session_id) || attachment_key

      snapshot
      |> value(:pending_permissions, [])
      |> List.wrap()
      |> Enum.map(&normalize_request(&1, attachment_key, session_id))
    end)
  end

  defp normalize_request(request, attachment_key, session_id) do
    request_id = request |> value(:request_id, "") |> safe_string()
    attachment_key = safe_string(attachment_key)
    session_id = safe_string(session_id, "Grok session")

    %{
      attachment_key: attachment_key,
      request_id: request_id,
      dom_id: Base.url_encode64(attachment_key <> ":" <> request_id, padding: false),
      session_id: session_id,
      session_label: compact_session_label(session_id),
      title: present_string(value(request, :title), "Grok needs permission to continue"),
      options:
        request
        |> value(:options, [])
        |> List.wrap()
        |> Enum.map(&normalize_option/1)
        |> Enum.reject(&(&1.option_id == ""))
    }
  end

  defp normalize_option(option) do
    %{
      option_id: option |> value(:option_id, "") |> safe_string(),
      name: present_string(value(option, :name), "Allow"),
      kind:
        option
        |> value(:kind, "allow_once")
        |> safe_string("allow_once")
        |> String.downcase()
    }
  end

  defp compact_session_label(session_id) when byte_size(session_id) > 28 do
    String.slice(session_id, 0, 12) <> "…" <> String.slice(session_id, -10, 10)
  end

  defp compact_session_label(session_id), do: session_id

  defp present_string(value, fallback) when is_binary(value) do
    if String.trim(value) == "", do: fallback, else: value
  end

  defp present_string(_value, fallback), do: fallback

  defp safe_string(value, fallback \\ "")
  defp safe_string(nil, fallback), do: fallback
  defp safe_string(value, _fallback) when is_binary(value), do: value
  defp safe_string(value, _fallback), do: to_string(value)

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp value(_map, _key, default), do: default
end
