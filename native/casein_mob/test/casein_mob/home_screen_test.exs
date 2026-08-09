defmodule CaseinMob.HomeScreenTest do
  # Tier-1 screen test: drives the screen in the BEAM, no device or emulator
  # needed. `use Mob.ScreenCase` gives mount_screen/3, render_event/3,
  # render_info/2, assigns/1, the tree queries (find / text / flatten), and
  # assert_renderable/2. See the `Mob.ScreenCase` docs for the full surface and
  # the testing-pyramid guidance: this is the fast tier you want most tests in.
  #
  # async: false because the home screen reads and writes the shared theme in
  # Mob.State. A screen that keeps all its state in assigns can use async: true.
  use Mob.ScreenCase, async: false

  alias CaseinMob.HomeScreen

  test "mounts and renders a tree the native layer can draw" do
    view = mount_screen(HomeScreen)
    # Asserts every node the screen emits is a type Compose / SwiftUI renders.
    assert_renderable(view)
    assert text(view) =~ "Casein"
    refute text(view) =~ "CaseinMob"
    assert find(view, :button, text: "Sessions")
  end

  test "switching to the light theme updates the assign and brand palette" do
    view = HomeScreen |> mount_screen() |> render_info({:tap, :theme_light})
    assert assigns(view).theme == :light
    assert Mob.Theme.current().primary == CaseinMob.Theme.light().primary
  end

  test "switching back to dark restores the brand dark palette" do
    view =
      HomeScreen
      |> mount_screen()
      |> render_info({:tap, :theme_light})
      |> render_info({:tap, :theme_dark})

    assert assigns(view).theme == :dark
    assert Mob.Theme.current().primary == CaseinMob.Theme.dark().primary
  end

  test "sessions is a first-class navigation target" do
    view = HomeScreen |> mount_screen() |> render_info({:tap, :open_sessions})
    assert navigated_to(view) == CaseinMob.SessionDashboardScreen
  end

  test "terminal navigation carries an explicit origin-qualified pinned target" do
    CaseinMob.SessionConfig.clear_all()

    CaseinMob.SessionConfig.put_pairing(%{
      origin_id: "origin-devbox",
      display_name: "Devbox",
      url: "https://casein.test",
      token: "token"
    })

    CaseinMob.SessionConfig.pin_workspace("ws-1")

    assert :ok =
             CaseinMob.SessionConfig.cache_cards("origin-devbox", [], nil, %{
               "mobile_terminal" => %{"enabled" => true}
             })

    view = HomeScreen |> mount_screen() |> render_info({:tap, :open_terminal})

    assert navigated_to(view) == CaseinMob.TerminalScreen

    assert view.socket.__mob__.nav_action ==
             {:push, CaseinMob.TerminalScreen,
              %{origin_id: "origin-devbox", workspace_id: "ws-1"}}
  end

  test "terminal entry is hidden when the server capability is disabled" do
    CaseinMob.SessionConfig.clear_all()

    CaseinMob.SessionConfig.put_pairing(%{
      origin_id: "origin-devbox",
      display_name: "Devbox",
      url: "https://casein.test",
      token: "token"
    })

    assert :ok =
             CaseinMob.SessionConfig.cache_cards("origin-devbox", [], nil, %{
               "mobile_terminal" => %{"enabled" => false, "reason" => "feature_disabled"}
             })

    view = mount_screen(HomeScreen)

    refute find(view, :button, text: "Terminal")

    view = render_info(view, {:tap, :open_terminal})
    refute navigated_to(view) == CaseinMob.TerminalScreen
  end

  test "terminal navigation carries a bounded error instead of selecting implicitly" do
    CaseinMob.SessionConfig.clear_all()

    CaseinMob.SessionConfig.put_pairing(%{
      origin_id: "origin-devbox",
      display_name: "Devbox",
      url: "https://casein.test",
      token: "token"
    })

    assert :ok =
             CaseinMob.SessionConfig.cache_cards("origin-devbox", [], nil, %{
               "mobile_terminal" => %{"enabled" => true}
             })

    view = HomeScreen |> mount_screen() |> render_info({:tap, :open_terminal})

    assert navigated_to(view) == CaseinMob.TerminalScreen

    assert view.socket.__mob__.nav_action ==
             {:push, CaseinMob.TerminalScreen, %{target_error: :workspace_not_selected}}
  end
end
