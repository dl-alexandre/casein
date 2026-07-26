defmodule CaseinMob.FileViewerScreenTest do
  use Mob.ScreenCase, async: false

  alias CaseinMob.FileViewerScreen

  test "mounts and renders while waiting for a devbox host" do
    view = mount_screen(FileViewerScreen, %{path: "mix.exs"})

    assert assigns(view).path == "mix.exs"
    assert assigns(view).status == "waiting for devbox"
    assert_renderable(view)
  end
end
