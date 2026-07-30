defmodule CaseinWeb.FlashJournalTest do
  @moduledoc """
  Error flashes reach the durable notification inbox.

  The value under test is that ~120 untouched `put_flash(socket, :error, ...)`
  call sites now leave a findable trace, so a failure the operator did not
  happen to be looking at is still recoverable from the bell drawer. Flashes are
  injected through `{:panel_flash, kind, msg}` — the same message LiveComponents
  already use to write the root flash — so no call site is special-cased here.
  """

  use CaseinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Casein.Notifications
  alias Casein.Test.Eventually

  setup do
    stub_manager_list([])
    :ok
  end

  defp stub_manager_list(payload) do
    Req.Test.stub(Casein.Integrations.Manager.Client, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end

  defp flash!(view, kind, message) do
    send(view.pid, {:panel_flash, kind, message})
    # Force a render: the recorder is an :after_render hook.
    render(view)
  end

  defp await_inbox(title) do
    Eventually.await(
      fn -> Enum.find(Notifications.list_for_user("dev"), &(&1.title == title)) end,
      message: "no durable notification titled #{inspect(title)}"
    )
  end

  defp inbox_titles do
    Notifications.list_for_user("dev") |> Enum.map(& &1.title)
  end

  test "an error flash lands in the durable inbox", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    flash!(view, :error, "Session template not found.")

    notification = await_inbox("Session template not found.")

    assert notification.severity == "error"
    assert notification.type == "ui_error"
    assert notification.source_type == "flash"
    assert notification.metadata["surface"] == "flash"
    assert notification.metadata["flash_kind"] == "error"
  end

  # A UI error is worth finding later; it is never worth waking a phone.
  test "recorded flashes are pinned to the in-app channel", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    flash!(view, :error, "Pinned to the inbox.")
    notification = await_inbox("Pinned to the inbox.")

    assert notification.channels == ["in_app"]
    assert notification.default_delivery["push"] == false
    assert notification.default_delivery["mobile"] == false
    assert notification.default_delivery["browser"] == false
  end

  test "info flashes are not recorded", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    flash!(view, :info, "Copied to clipboard")
    # Give the (absent) async write the same chance to land as a real one.
    flash!(view, :error, "Sentinel error.")
    await_inbox("Sentinel error.")

    refute "Copied to clipboard" in inbox_titles()
  end

  test "the unread badge counts a recorded flash", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    flash!(view, :error, "Counted by the badge.")
    await_inbox("Counted by the badge.")

    Eventually.await(
      fn -> Notifications.unread_count("dev") > 0 end,
      message: "recorded flash did not reach the unread count"
    )
  end

  # Re-rendering must not file the same failure once per diff.
  test "repeated renders of one flash record a single row", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    flash!(view, :error, "Rendered more than once.")
    await_inbox("Rendered more than once.")

    render(view)
    render(view)

    assert Enum.count(inbox_titles(), &(&1 == "Rendered more than once.")) == 1
  end

  # The recorder tracks the *absence* of a flash too. Without that, clearing and
  # re-raising the identical error would be silently swallowed for the life of
  # the LiveView.
  test "an identical error recorded again after the flash clears is grouped, not dropped",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    flash!(view, :error, "Happened twice.")
    notification = await_inbox("Happened twice.")
    assert notification.occurrence_count == 1

    # What FlashBridge does client-side once it has hoisted the message.
    render_click(view, "lv:clear-flash", %{"key" => "error"})
    flash!(view, :error, "Happened twice.")

    Eventually.await(
      fn ->
        match?(
          %{occurrence_count: 2},
          Enum.find(Notifications.list_for_user("dev"), &(&1.title == "Happened twice."))
        )
      end,
      message: "the second occurrence was dropped instead of grouped"
    )

    assert Enum.count(inbox_titles(), &(&1 == "Happened twice.")) == 1
  end

  test "an over-long flash is truncated to the title limit", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    long = String.duplicate("z", 400)
    flash!(view, :error, long)

    notification =
      Eventually.await(
        fn ->
          Enum.find(Notifications.list_for_user("dev"), &String.starts_with?(&1.title, "zzz"))
        end,
        message: "long flash was never recorded"
      )

    assert String.length(notification.title) == 240
    assert String.ends_with?(notification.title, "…")
  end

  test "a blank flash is ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    flash!(view, :error, "   ")
    flash!(view, :error, "Sentinel after blank.")
    await_inbox("Sentinel after blank.")

    refute Enum.any?(inbox_titles(), &(String.trim(&1) == ""))
  end

  test "the disconnected mount records nothing", %{conn: conn} do
    html = get(conn, ~p"/") |> html_response(200)

    assert html =~ "casein-toast-root"
    assert inbox_titles() == []
  end
end
