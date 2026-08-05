defmodule CaseinMob.TerminalScreenTest do
  use Mob.ScreenCase, async: false

  alias CaseinMob.TerminalScreen

  test "renders an explicit read-only unavailable surface without input affordances" do
    view = mount_screen(TerminalScreen)

    assert_renderable(view, extra: [:canvas])
    assert find(view, :button, text: "Back")
    assert text(view) =~ "Terminal"
    assert text(view) =~ "Read-only · input is disabled"
    assert text(view) =~ "No authorized workspace"
    assert text(view) =~ "Unavailable"

    refute find(view, :text_field)
    refute find(view, :button, text: "Esc")
    refute find(view, :button, text: "Tab")
    refute find(view, :button, text: "^C")
    refute find(view, :button, text: "^D")
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
      TerminalScreen
      |> mount_screen()
      |> render_info({:mobile_terminal_baseline, metadata, "ready"})

    assert text(view) =~ "Live"
    assert text(view) =~ "Devbox · ws-1"
    assert find(view, :box, id: "terminal-surface").props.fresh_baseline_generation == 7
  end

  test "background covers output and removes the old freshness signal" do
    metadata = %{
      origin_name: "Devbox",
      workspace_id: "ws-1",
      fresh_baseline_generation: 7
    }

    view =
      TerminalScreen
      |> mount_screen()
      |> render_info({:mobile_terminal_baseline, metadata, "ready"})
      |> render_info(:app_background)

    assert find(view, :box, id: "terminal-surface").props.fresh_baseline_generation == nil
  end

  test "back uses the normal navigation stack" do
    view =
      TerminalScreen
      |> mount_screen()
      |> render_info({:tap, :back})

    assert navigated_to(view) == {:pop}
  end
end
