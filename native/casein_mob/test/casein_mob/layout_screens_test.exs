defmodule CaseinMob.LayoutScreensTest do
  @moduledoc """
  Guards the wiring, not the transform.

  A screen that declares `gap:` and returns its tree directly renders flush on
  device while every unit test still passes — that is exactly how the original
  bug survived. The source-level check catches a screen added later without
  needing to mount it (several screens need a repo or a live channel to mount).
  """
  use Mob.ScreenCase, async: false

  alias CaseinMob.SessionDashboardScreen

  @screen_sources Path.wildcard("lib/casein_mob/*_screen.ex")

  test "every screen that declares a gap routes its render through CaseinMob.Layout" do
    offenders =
      for path <- @screen_sources,
          source = File.read!(path),
          String.contains?(source, "gap:"),
          not String.contains?(source, "Layout.materialize("),
          do: path

    assert offenders == [],
           "these screens declare `gap:` but never materialise it, so their spacing is " <>
             "dropped by both native renderers: #{Enum.join(offenders, ", ")}"
  end

  test "the dashboard's declared spacing survives as real spacer nodes" do
    view = mount_screen(SessionDashboardScreen)

    spacers = view |> flatten() |> Enum.filter(&(&1.type == :spacer))
    leaked = view |> flatten() |> Enum.filter(&Map.has_key?(&1.props, :gap))

    assert spacers != [], "the dashboard declares gaps but rendered no spacers"
    assert Enum.all?(spacers, &(is_number(&1.props.size) and &1.props.size > 0))
    assert leaked == []
  end

  test "the screen wildcard actually matched something" do
    # Guards against the check silently passing because the glob broke.
    assert length(@screen_sources) >= 7
  end
end
