defmodule CaseinWeb.WorkspaceLive.Show.GrokPermissionEventsTest do
  # Attachments GenServer + Audit.MemoryAdapter on decision error paths.
  use Casein.TestCase, async: false

  alias CaseinWeb.WorkspaceLive.Show.GrokPermissionEvents

  # Pure: mount (not connected), handle_info snapshot normalize/mismatch,
  # invalid catch-all event, respond/cancel when Attachments has no entry.
  # SKIPPED happy-path respond/cancel (need a live GrokACP attachment pid).

  defp socket(assigns) do
    ws_id = "ws-grok-perm-#{System.unique_integer([:positive])}"

    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            flash: %{},
            workspace: %{id: ws_id},
            current_user: %{id: "actor-#{System.unique_integer([:positive])}"},
            codex_pending_requests: [],
            grok_permission_requests: []
          },
          assigns
        )
    }
  end

  test "mount seeds an empty permission list when not connected" do
    s = socket(%{grok_permission_requests: :stale})
    s2 = GrokPermissionEvents.mount(s)
    assert s2.assigns.grok_permission_requests == []
  end

  test "handle_info normalizes attachment snapshots for the matching workspace" do
    ws_id = "ws-grok-perm-#{System.unique_integer([:positive])}"

    s =
      socket(%{
        workspace: %{id: ws_id},
        codex_pending_requests: [%{provider_id: :codex, request_id: "codex-1"}]
      })

    snapshots = [
      %{
        attachment_key: "att-1",
        session_id: "session-abcdefghijklmnopqrstuvwxyz-tail",
        pending_permissions: [
          %{
            request_id: "req-9",
            title: "  ",
            options: [
              %{option_id: "allow", name: "Allow once", kind: "ALLOW_ONCE"},
              %{option_id: "", name: "drop-me", kind: "allow_once"}
            ]
          }
        ]
      }
    ]

    s2 =
      GrokPermissionEvents.handle_info(
        {:grok_acp_attachments_updated, ws_id, snapshots},
        s
      )

    assert [req] = s2.assigns.grok_permission_requests
    assert s2.assigns.agent_pending_approval_count == 2
    assert req.provider_id == :grok_acp
    assert req.session_ref.workspace_id == ws_id
    assert req.session_ref.attachment_key == "att-1"
    assert req.request_id == "req-9"
    assert req.title == "Grok needs permission to continue"
    assert req.detail =~ "…"
    assert [%{id: "allow", label: "Allow once", kind: "allow_once"}] = req.options
  end

  test "handle_info ignores snapshots for a different workspace" do
    s = socket(%{grok_permission_requests: [%{request_id: "keep"}]})

    s2 =
      GrokPermissionEvents.handle_info(
        {:grok_acp_attachments_updated, "other-ws", [%{pending_permissions: []}]},
        s
      )

    assert s2.assigns.grok_permission_requests == [%{request_id: "keep"}]
  end

  test "handle_info with a non-list snapshots payload is ignored" do
    ws_id = "ws-grok-perm-#{System.unique_integer([:positive])}"
    s = socket(%{workspace: %{id: ws_id}, grok_permission_requests: [:prior]})

    # Matching workspace_id but non-list snapshots falls through to the catch-all.
    s2 =
      GrokPermissionEvents.handle_info(
        {:grok_acp_attachments_updated, ws_id, :not_a_list},
        s
      )

    assert s2.assigns.grok_permission_requests == [:prior]
  end
end
