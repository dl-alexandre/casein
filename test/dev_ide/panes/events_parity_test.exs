defmodule DevIDE.Panes.EventsParityTest do
  # Parity harness for the preview runtime cutover: every legacy "preview:"
  # lifecycle broadcast from DevIDE.PreviewPanes must be mirrored by a generic
  # DevIDE.Panes.Events event with an equivalent payload, so the web layer can
  # switch its preview state maintenance from the legacy topic to the generic
  # one without losing a channel.
  use DevIDE.DataCase, async: false

  alias DevIDE.Panes
  alias DevIDE.Panes.Events
  alias DevIDE.PreviewPanes
  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  setup do
    prev_tmux = Application.get_env(:dev_ide, :tmux_adapter)
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_persistence = Application.get_env(:dev_ide, :preview_pane_persistence_enabled)
    Application.put_env(:dev_ide, :tmux_adapter, FakeAdapter)
    Application.put_env(:dev_ide, :preview_pane_persistence_enabled, true)
    PreviewPanes.clear()
    FakeState.delete(:fake_tmux_windows)
    FakeState.delete(:fake_tmux_panes)

    on_exit(fn ->
      PreviewPanes.clear()
      FakeState.delete(:fake_tmux_windows)
      FakeState.delete(:fake_tmux_panes)
      restore(:tmux_adapter, prev_tmux)
      restore(:workspaces_root, prev_root)
      restore(:preview_pane_persistence_enabled, prev_persistence)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)

  defp seed_workspace! do
    root = DevIDE.TmpWorkspace.root!("pane-events")
    path = Path.join(root, "ws")
    File.mkdir_p!(path)
    Application.put_env(:dev_ide, :workspaces_root, root)
    {root, path}
  end

  defp seed_session!(session, pane_id) do
    FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "bash", active: true, panes: 1, activity: 0}]
    })

    FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: pane_id,
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "devide-preview",
          current_path: "/tmp"
        }
      ]
    })
  end

  test "register/heartbeat/deregister dual-broadcast onto Panes.Events with matching payloads" do
    {_root, path} = seed_workspace!()
    session = "devide_pane_events_1"
    pane_id = "%31"
    seed_session!(session, pane_id)
    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)

    :ok = Phoenix.PubSub.subscribe(DevIDE.PubSub, "preview:" <> workspace_id)
    [_ | _] = Events.subscribe(workspace_id)

    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "https://example.com/app",
               "cwd" => path,
               "tmux_session" => session
             })

    # Legacy and generic events fire for the same registration...
    assert_receive {:preview_pane_registered, legacy}
    assert_receive {:pane_event, %{reason: :registered, type: :preview} = evt}

    # ...with an equivalent payload (the generic payload is render_payload/1's
    # shape — assert every field the web layer's preview pane map consumes).
    assert evt.pane_id == legacy.pane_id
    assert evt.workspace_id == workspace_id
    assert evt.tmux_session == legacy.tmux_session
    assert evt.payload.url == legacy.url
    assert evt.payload.display_url == legacy.display_url
    assert evt.payload.viewport == legacy.viewport
    assert evt.payload.workspace_id == legacy.workspace_id
    assert evt.payload.preview_id == legacy.preview_id
    assert evt.payload.control_session_id == legacy.control_session_id
    assert evt.payload.shared == legacy.shared
    assert evt.payload.source_pane_id == legacy.source_pane_id

    # The generic payload matches what snapshot/1 hydration would produce.
    snapshot = Panes.snapshot(workspace_id)
    assert %{type: :preview, payload: payload} = snapshot[pane_id]
    assert payload == evt.payload

    # A heartbeat re-register maps to the explicit :heartbeat reason (the web
    # layer's focus-churn guard keys off it), still alongside the legacy event.
    assert {:ok, _} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "https://example.com/app",
               "cwd" => path,
               "tmux_session" => session,
               "heartbeat" => "1"
             })

    assert_receive {:preview_pane_registered, _heartbeat_legacy}
    assert_receive {:pane_event, %{reason: :heartbeat, type: :preview, pane_id: ^pane_id} = hb}
    assert hb.payload.display_url == registration.display_url

    # Removal mirrors the legacy removed broadcast with an empty payload.
    assert :ok = PreviewPanes.deregister(pane_id)
    assert_receive {:preview_pane_removed, removed_legacy}
    assert_receive {:pane_event, %{reason: :removed, type: :preview} = removed}
    assert removed.pane_id == removed_legacy.pane_id
    assert removed.payload == %{}
    refute Map.has_key?(Panes.snapshot(workspace_id), pane_id)
  end
end
