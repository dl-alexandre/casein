defmodule DevIDE.PreviewActivityTest do
  use DevIde.DataCase, async: false

  alias DevIDE.PreviewActivity

  setup do
    PreviewActivity.clear()

    on_exit(fn ->
      PreviewActivity.clear()
    end)

    :ok
  end

  test "records and broadcasts bounded preview pane activity" do
    :ok = PreviewActivity.subscribe("ws-activity")

    entry =
      PreviewActivity.record(%{
        workspace_id: "ws-activity",
        pane_id: "%12",
        session_id: "42",
        preview_id: 7,
        source: :browser,
        event: "pointer_down",
        summary: "pointer down @ 10,20",
        metadata: %{"x" => 10, "y" => 20}
      })

    assert_receive {:preview_activity, ^entry}

    assert entry.session_id == 42
    assert entry.preview_id == 7
    assert entry.source == :browser
    assert entry.metadata == %{"x" => 10, "y" => 20}

    assert [^entry] = PreviewActivity.recent_workspace("ws-activity", 10)
    assert [^entry] = PreviewActivity.recent_pane("ws-activity", "%12", 10)
    assert PreviewActivity.latest_pane("ws-activity", "%12") == entry
    assert PreviewActivity.recent_pane("ws-activity", "%13", 10) == []
  end

  test "keeps newest activity first and respects limits" do
    first =
      PreviewActivity.record(%{
        workspace_id: "ws-activity",
        pane_id: "%12",
        event: "entered",
        summary: "preview pane entered"
      })

    second =
      PreviewActivity.record(%{
        workspace_id: "ws-activity",
        pane_id: "%12",
        event: "exited",
        summary: "preview pane exited"
      })

    assert [^second] = PreviewActivity.recent_pane("ws-activity", "%12", 1)
    assert [^second, ^first] = PreviewActivity.recent_workspace("ws-activity", 2)
  end
end
