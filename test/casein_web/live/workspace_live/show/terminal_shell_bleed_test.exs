defmodule CaseinWeb.WorkspaceLive.Show.TerminalShellBleedTest do
  use ExUnit.Case, async: true

  @panel "lib/casein_web/live/workspace_live/show/terminal_panel.ex"
  @shell "lib/casein_web/live/workspace_live/show/workspace_shell.ex"

  # Every terminal lost its first two glyph columns — "./casein_core" painted as
  # "casein_core" — because .terminal-shell bled -mx-4 / max-sm:-mx-2 / lg:-mx-6
  # to cancel workspace_shell's padding and reach the window edges. It never
  # reached them: the only parent it renders under is #terminal-region, which
  # sits INSIDE that padding and clips with overflow-hidden. The bleed painted
  # nothing new and instead pushed the outermost 24px of live grid (the pre's own
  # padding plus two glyph columns) past the clip on each side, while the fit
  # still measured the wider bled box and sized tmux ~6 columns too wide.
  #
  # These two facts only make sense together, so assert them together: the bleed
  # may come back only if the clipping parent goes away.
  test "the terminal shell does not bleed horizontally past its clipping parent" do
    class =
      Regex.run(~r/<section class="(terminal-shell[^"]*)"/, File.read!(@panel),
        capture: :all_but_first
      )

    assert [class] = class, "expected a <section class=\"terminal-shell ...\"> in #{@panel}"

    refute class =~ "-mx-",
           """
           .terminal-shell must not carry a negative horizontal margin while
           #terminal-region clips it: the bled columns are painted outside the
           clip and silently lost. Found: #{class}
           """

    assert File.read!(@shell) =~ ~r/data-terminal-region="true".*?overflow-hidden/s,
           "#terminal-region no longer clips — re-check the bleed before restoring it"
  end
end
