defmodule CaseinWeb.WorkspaceLive.Show.GrokPermissionEvents do
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView, only: [connected?: 1]

  alias Casein.AgentSessions.GrokACP.Attachments
  alias Casein.AgentSessions.Provider.PendingRequest

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
    assign(socket, :grok_permission_requests, normalize_requests(snapshots, workspace_id))
  end

  def handle_info({:grok_acp_attachments_updated, _workspace_id, _snapshots}, socket), do: socket

  def refresh(socket) do
    workspace_id = socket.assigns.workspace.id
    requests = workspace_id |> Attachments.list() |> normalize_requests(workspace_id)

    assign(socket, :grok_permission_requests, requests)
  catch
    :exit, _reason -> assign(socket, :grok_permission_requests, [])
  end

  defp normalize_requests(snapshots, workspace_id) do
    Enum.flat_map(snapshots, fn snapshot ->
      attachment_key = value(snapshot, :attachment_key)
      session_id = value(snapshot, :session_id) || attachment_key

      snapshot
      |> value(:pending_permissions, [])
      |> List.wrap()
      |> Enum.map(&normalize_request(&1, workspace_id, attachment_key, session_id))
    end)
  end

  defp normalize_request(request, workspace_id, attachment_key, session_id) do
    request_id = request |> value(:request_id, "") |> safe_string()
    attachment_key = safe_string(attachment_key)
    session_id = safe_string(session_id, "Grok session")

    PendingRequest.new(%{
      provider_id: :grok_acp,
      session_ref: %{
        provider_id: :grok_acp,
        workspace_id: workspace_id,
        attachment_key: attachment_key
      },
      request_id: request_id,
      title: present_string(value(request, :title), "Grok needs permission to continue"),
      detail: compact_session_label(session_id),
      options:
        request
        |> value(:options, [])
        |> List.wrap()
        |> Enum.map(&normalize_option/1)
        |> Enum.reject(&(&1.id == "")),
      metadata: %{session_id: session_id}
    })
  end

  defp normalize_option(option) do
    %{
      id: option |> value(:option_id, "") |> safe_string(),
      label: present_string(value(option, :name), "Allow"),
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
