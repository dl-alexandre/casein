defmodule CaseinWeb.WorkspaceLive.Show.HandleInfoDecompositionTest do
  use Casein.TestCase, async: true

  # Constraints for #933 (show.ex handle_info extract). Encoded here so a
  # follow-up cannot silently undo the split or "fix" the known tracking trap
  # as a side effect of moving more clauses.

  @show_path "lib/casein_web/live/workspace_live/show.ex"
  @show_src File.read!(@show_path)

  test "PTY and after-mount handle_info clauses delegate; bodies live in submodules" do
    for needle <- [
          "do: PtyEvents.handle_info(msg, socket)",
          "{:pty_data, _pane_id, data}",
          "{:pane_frame, _, _}",
          "{:pty_exit, _, _}",
          "{:terminal_recovery, %{type: :session_recreated}}",
          "{:auto_apply_recovery_template, template_id}",
          "{:auto_reattach_pane, _, _}",
          "do: AfterMount.handle_info(msg, socket)",
          ":after_mount_side_panels = msg",
          ":after_mount_runs = msg",
          ":after_mount_agents = msg"
        ] do
      assert @show_src =~ needle, "show.ex must still dispatch #{inspect(needle)}"
    end

    refute @show_src =~ "defp push_osc52_clipboard",
           "OSC52 helpers moved with PtyEvents — do not leave a copy in Show"

    refute @show_src =~ "defp maybe_auto_reattach_pane",
           "auto-reattach helpers moved with PtyEvents — do not leave a copy in Show"

    refute @show_src =~ "defp fetch_side_panels(",
           "after-mount fetch wrappers moved with AfterMount — do not leave a copy in Show"
  end

  test "do not 'fix' LiveView tracking by splatting assigns or stuffing :__changed__" do
    # The whole workspace shell re-renders on every LV update when the call
    # is `<.workspace_shell {assigns}>` or `{terminal_tab_attrs(assigns)}`.
    # Adding :__changed__ to a Map.take does NOT restore tracking — the engine
    # disables it for any assigns-dependent dynamic part. That is a separate
    # problem; this extract must not touch it.
    refute @show_src =~ ~r/workspace_shell\s+\{assigns\}/,
           "do not reintroduce <.workspace_shell {assigns}> while decomposing handle_info"

    refute @show_src =~ ~r/terminal_tab_attrs\(assigns\)/,
           "do not reintroduce {terminal_tab_attrs(assigns)} while decomposing handle_info"

    refute @show_src =~ ~r/Map\.take\([^)]*:__changed__/,
           "adding :__changed__ to Map.take does not restore LV tracking; do not try it here"
  end

  test "handle_event dispatch table and authz_gate stay in Show" do
    assert @show_src =~ "@direct_events"
    assert @show_src =~ "@known_events @direct_events ++ @palette_events"
    assert @show_src =~ "defp authz_gate(event, params, socket) do"
    assert @show_src =~ "fleet_drawer:"
    assert @show_src =~ "do: FleetEvents.handle_event(event, params, socket)"
  end
end
