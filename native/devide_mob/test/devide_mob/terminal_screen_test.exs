defmodule DevideMob.TerminalScreenTest do
  use Mob.ScreenCase, async: false

  alias DevideMob.TerminalScreen

  test "renders as a secondary utility with app chrome and terminal-only controls" do
    view = mount_screen(TerminalScreen)

    assert_renderable(view, extra: [:canvas])
    assert find(view, :button, text: "Back")
    assert text(view) =~ "Terminal"
    assert text(view) =~ "Grid 80x24"

    refute find(view, :button, text: "Files")
    refute find(view, :button, text: "Apps")
    refute find(view, :button, text: "Sessions")

    assert find(view, :button, text: "Esc")
    assert find(view, :button, text: "Tab")
    assert find(view, :button, text: "^C").props.height == 36.0
    assert find(view, :button, text: "^D").props.height == 36.0
  end

  test "back uses the normal navigation stack" do
    view =
      TerminalScreen
      |> mount_screen()
      |> render_info({:tap, :back})

    assert navigated_to(view) == {:pop}
  end

  test "host bridge status takes precedence when connected" do
    view =
      TerminalScreen
      |> mount_screen()
      |> render_info({:vt_host, self()})

    assert text(view) =~ "Devbox connected"
  end
end
