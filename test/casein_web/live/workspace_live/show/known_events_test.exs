defmodule CaseinWeb.WorkspaceLive.Show.KnownEventsTest do
  use Casein.TestCase, async: true

  alias Casein.CommandPalette.Actions
  alias CaseinWeb.WorkspaceLive.Show

  describe "@known_events derivation" do
    test "every event the palette may dispatch is admitted by the gate" do
      # This used to be two hand-maintained lists. When they drifted, the
      # palette offered an action that authz_gate/3 then denied — surfacing as
      # "that action isn't available here" rather than as a stale allowlist.
      # Deriving one from the other makes that unrepresentable; this test is
      # the guard against someone re-introducing a literal list.
      known = MapSet.new(Show.known_events())

      unreachable =
        Actions.allowed_events()
        |> Enum.reject(fn event ->
          MapSet.member?(known, event) or
            String.starts_with?(event, "tmux:") or
            String.starts_with?(event, "terminal:")
        end)

      assert unreachable == [],
             "palette can dispatch events the gate denies: #{inspect(unreachable)}"
    end

    test "the allowlist still covers direct-manipulation events with no palette entry" do
      # Spot-check a few events the palette deliberately does not expose, so
      # collapsing the two halves cannot quietly drop the non-palette one.
      known = MapSet.new(Show.known_events())

      for event <- ~w(ctx:open ctx:close file:save pane:input palette:execute
                      notifications:toggle preview-pane:enter workspace:start) do
        assert MapSet.member?(known, event), "#{event} fell out of the allowlist"
      end
    end
  end
end
