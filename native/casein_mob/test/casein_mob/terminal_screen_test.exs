defmodule CaseinMob.TerminalScreenTest do
  use Mob.ScreenCase, async: false

  alias CaseinMob.{SessionConfig, Terminal, TerminalScreen}

  test "platform routing never sends iOS through the Android-only Ghostty NIF" do
    assert Terminal.backend(:ios) == :ios_canvas
    assert Terminal.backend(:android) == :ghostty_vt
    assert Terminal.backend(:host) == :host_ghostty

    source = File.read!(Path.expand("../../lib/casein_mob/terminal_screen.ex", __DIR__))

    assert source =~ "IOSTerminalComponent.widget("
    assert source =~ "%{terminal_backend: :ios_canvas}"
    assert source =~ "Terminal.write(term, bytes)"
  end

  test "renders an explicit read-only unavailable surface without input affordances" do
    view = mount_screen(TerminalScreen)

    assert_renderable(view, extra: [:canvas])
    assert find(view, :button, text: "Back")
    assert text(view) =~ "Terminal"
    assert text(view) =~ "Read-only · input is disabled"
    assert text(view) =~ "Select a workspace before opening Terminal"
    assert text(view) =~ "Unavailable"

    refute find(view, :text_field)
    refute find(view, :button, text: "Esc")
    refute find(view, :button, text: "Tab")
    refute find(view, :button, text: "^C")
    refute find(view, :button, text: "^D")
  end

  test "mount revalidates an explicit origin-qualified workspace target" do
    SessionConfig.clear_all()

    SessionConfig.put_pairing(%{
      origin_id: "origin-devbox",
      display_name: "Devbox",
      url: "https://casein.test",
      token: "token"
    })

    SessionConfig.pin_workspace("ws-1")

    view =
      mount_screen(TerminalScreen, %{
        origin_id: "origin-devbox",
        workspace_id: "ws-1"
      })

    assert assigns(view).origin_id == "origin-devbox"
    assert assigns(view).workspace_id == "ws-1"
    assert assigns(view).status == :connecting
    assert assigns(view).unavailable_reason == nil

    stale =
      mount_screen(TerminalScreen, %{
        origin_id: "origin-old",
        workspace_id: "ws-1"
      })

    assert assigns(stale).workspace_id == nil
    assert assigns(stale).status == :unavailable
    assert assigns(stale).unavailable_reason == :inactive_origin
    assert text(stale) =~ "Selected workspace belongs to an inactive origin"
  end

  test "empty params never select a pinned workspace implicitly" do
    SessionConfig.clear_all()

    SessionConfig.put_pairing(%{
      origin_id: "origin-devbox",
      display_name: "Devbox",
      url: "https://casein.test",
      token: "token"
    })

    SessionConfig.pin_workspace("ws-1")

    view = mount_screen(TerminalScreen, %{})

    assert assigns(view).workspace_id == nil
    assert assigns(view).status == :unavailable
    assert assigns(view).unavailable_reason == :workspace_not_selected
  end

  test "an authoritative baseline exposes its freshness generation and metadata" do
    metadata = %{
      origin_id: "origin-1",
      origin_name: "Devbox",
      workspace_id: "ws-1",
      expires_at: "2026-08-05T00:00:00Z",
      fresh_baseline_generation: 7
    }

    view =
      mounted_terminal()
      |> render_info({:mobile_terminal_baseline, metadata, "ready"})

    assert text(view) =~ "Live"
    assert text(view) =~ "Devbox · ws-1"
    assert find(view, :box, id: "terminal-surface").props.fresh_baseline_generation == 7
  end

  test "baseline and status identity mismatches fail closed without retargeting" do
    view = mounted_terminal()

    mismatched_baseline =
      render_info(
        view,
        {:mobile_terminal_baseline,
         %{origin_id: "origin-other", workspace_id: "ws-1", fresh_baseline_generation: 1},
         "fixture"}
      )

    assert assigns(mismatched_baseline).origin_id == "origin-1"
    assert assigns(mismatched_baseline).workspace_id == "ws-1"
    assert assigns(mismatched_baseline).status == :unavailable
    refute assigns(mismatched_baseline).baseline_ready?

    mismatched_status =
      render_info(
        view,
        {:mobile_terminal_status, "ws-other", :live, %{origin_id: "origin-1"}}
      )

    assert assigns(mismatched_status).origin_id == "origin-1"
    assert assigns(mismatched_status).workspace_id == "ws-1"
    assert assigns(mismatched_status).status == :unavailable

    missing_origin =
      render_info(view, {:mobile_terminal_status, "ws-1", :live, %{}})

    assert assigns(missing_origin).origin_id == "origin-1"
    assert assigns(missing_origin).workspace_id == "ws-1"
    assert assigns(missing_origin).status == :unavailable

    for malformed <- [nil, "bad", []] do
      rejected =
        render_info(view, {:mobile_terminal_status, "ws-1", :live, malformed})

      assert assigns(rejected).origin_id == "origin-1"
      assert assigns(rejected).workspace_id == "ws-1"
      assert assigns(rejected).status == :unavailable
      refute assigns(rejected).baseline_ready?
    end
  end

  test "background covers output and removes the old freshness signal" do
    metadata = %{
      origin_name: "Devbox",
      origin_id: "origin-1",
      workspace_id: "ws-1",
      fresh_baseline_generation: 7
    }

    view =
      mounted_terminal()
      |> render_info({:mobile_terminal_baseline, metadata, "ready"})
      |> render_info(:app_background)

    assert find(view, :box, id: "terminal-surface").props.fresh_baseline_generation == nil
  end

  test "iOS consumption scrubs the encoded transport copy without re-encoding active raw state" do
    metadata = %{
      origin_name: "Devbox",
      origin_id: "origin-1",
      workspace_id: "ws-1",
      fresh_baseline_generation: 7
    }

    view =
      mounted_terminal()
      |> ios_backend()
      |> render_info({:mobile_terminal_baseline, metadata, "fixture"})

    assert assigns(view).ios_frame == "fixture"
    assert assigns(view).ios_delivery_pending?
    assert native_terminal_props(view).encoded_frame == Base.encode64("fixture")

    consumed = render_info(view, {:ios_terminal_consumed, 7, assigns(view).ios_revision})

    assert assigns(consumed).ios_frame == "fixture"
    refute assigns(consumed).ios_delivery_pending?
    assert native_terminal_props(consumed).encoded_frame == ""
    assert native_terminal_props(consumed).delivery_state == :consumed
  end

  test "iOS allows only one revision-bound encoded delivery and coalesces output behind it" do
    metadata = %{
      origin_name: "Devbox",
      origin_id: "origin-1",
      workspace_id: "ws-1",
      fresh_baseline_generation: 7
    }

    baseline =
      mounted_terminal()
      |> ios_backend()
      |> render_info({:mobile_terminal_baseline, metadata, "base"})

    baseline_revision = assigns(baseline).ios_revision
    queued = render_info(baseline, {:mobile_terminal_output, "next"})

    assert assigns(queued).ios_revision == baseline_revision
    assert assigns(queued).ios_frame == "base"
    assert assigns(queued).ios_queued_output == "next"
    assert native_terminal_props(queued).encoded_frame == Base.encode64("base")

    next_delivery = render_info(queued, {:ios_terminal_consumed, 7, baseline_revision})
    assert assigns(next_delivery).ios_revision == baseline_revision + 1
    assert assigns(next_delivery).ios_frame == "basenext"
    assert assigns(next_delivery).ios_queued_output == ""
    assert assigns(next_delivery).ios_delivery_pending?
    assert native_terminal_props(next_delivery).encoded_frame == Base.encode64("basenext")

    stale_ack = render_info(next_delivery, {:ios_terminal_consumed, 7, baseline_revision})
    assert assigns(stale_ack).ios_delivery_pending?
    assert assigns(stale_ack).ios_frame == "basenext"
    assert native_terminal_props(stale_ack).encoded_frame == Base.encode64("basenext")

    consumed =
      render_info(stale_ack, {:ios_terminal_consumed, 7, baseline_revision + 1})

    refute assigns(consumed).ios_delivery_pending?
    assert assigns(consumed).ios_frame == "basenext"
    assert native_terminal_props(consumed).encoded_frame == ""
  end

  test "iOS lifecycle and ack timeout purge raw and encoded copies before any foreground render" do
    metadata = %{
      origin_name: "Devbox",
      origin_id: "origin-1",
      workspace_id: "ws-1",
      fresh_baseline_generation: 7
    }

    live =
      mounted_terminal()
      |> ios_backend()
      |> render_info({:mobile_terminal_baseline, metadata, "fixture"})

    timed_out =
      render_info(
        live,
        {:ios_terminal_ack_timeout, 7, assigns(live).ios_revision}
      )

    assert assigns(timed_out).ios_frame == ""
    assert assigns(timed_out).ios_queued_output == ""
    refute assigns(timed_out).ios_delivery_pending?
    refute assigns(timed_out).baseline_ready?
    assert native_terminal_props(timed_out).encoded_frame == ""
    assert native_terminal_props(timed_out).delivery_state == :covered

    backgrounded = render_info(live, :app_background)
    assert assigns(backgrounded).ios_frame == ""
    assert assigns(backgrounded).ios_queued_output == ""
    refute assigns(backgrounded).ios_delivery_pending?
    refute assigns(backgrounded).baseline_ready?
    assert native_terminal_props(backgrounded).encoded_frame == ""
  end

  test "invalid native acknowledgment purges active raw state and requires resync" do
    metadata = %{
      origin_name: "Devbox",
      origin_id: "origin-1",
      workspace_id: "ws-1",
      fresh_baseline_generation: 7
    }

    view =
      mounted_terminal()
      |> ios_backend()
      |> render_info({:mobile_terminal_baseline, metadata, "fixture"})
      |> render_info(:ios_terminal_invalid_consumption)

    assert assigns(view).ios_frame == ""
    assert assigns(view).ios_queued_output == ""
    refute assigns(view).ios_delivery_pending?
    refute assigns(view).baseline_ready?
    assert native_terminal_props(view).delivery_state == :covered
  end

  test "back uses the normal navigation stack" do
    view =
      TerminalScreen
      |> mount_screen()
      |> render_info({:tap, :back})

    assert navigated_to(view) == {:pop}
  end

  defp ios_backend(view) do
    socket =
      view.socket
      |> Mob.Socket.assign(:terminal_backend, :ios_canvas)
      |> Mob.Socket.assign(:term, :ios_canvas)

    %{view | socket: socket}
  end

  defp mounted_terminal do
    view = mount_screen(TerminalScreen)

    socket =
      view.socket
      |> Mob.Socket.assign(:origin_id, "origin-1")
      |> Mob.Socket.assign(:origin_name, "Devbox")
      |> Mob.Socket.assign(:workspace_id, "ws-1")
      |> Mob.Socket.assign(:unavailable_reason, nil)
      |> Mob.Socket.assign(:status, :connecting)

    %{view | socket: socket}
  end

  defp native_terminal_props(view) do
    view
    |> find(:native_view, id: :ios_terminal_surface)
    |> Map.fetch!(:props)
  end
end
