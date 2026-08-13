defmodule CaseinWeb.WorkspaceLive.HotPathBlockingTest do
  use ExUnit.Case, async: true

  alias Casein.Workspace
  alias CaseinWeb.LiveDiffMeasure
  alias CaseinWeb.WorkspaceLive.Show.TerminalEvents

  # #923: no System.cmd / :os.cmd / HTTP / Process.sleep inline in these
  # LiveView event/info paths. Briefs die with the pane — this test is the
  # constraint.
  @lv_sources [
    "lib/casein_web/live/workspace_live/show/terminal_events.ex",
    "lib/casein_web/live/workspace_live/show/terminal_state.ex"
  ]

  @forbidden [
    {~r/Process\.sleep\s*\(/, "Process.sleep"},
    {~r/System\.cmd\s*\(/, "System.cmd"},
    {~r/:os\.cmd\s*\(/, ":os.cmd"},
    {~r/Req\.(get|post|request)\s*\(/, "Req HTTP"}
  ]

  test "LiveView hot-path sources do not block inline (#923)" do
    for path <- @lv_sources do
      source = File.read!(Path.join(File.cwd!(), path))

      for {pattern, label} <- @forbidden do
        refute Regex.match?(pattern, source),
               "#{path} still has #{label} inline — move it off handle_event/handle_info (#923)"
      end
    end

    state =
      File.read!(
        Path.join(File.cwd!(), "lib/casein_web/live/workspace_live/show/terminal_state.ex")
      )

    assert state =~ "OrphanedClaims.cached_list",
           "assign_tmux_window_tabs must peek cached claims, not list_claimed/0"

    assert state =~ "GateQueue.cached",
           "assign_tmux_window_tabs must peek GateQueue.cached, not observe/0"

    pane_open =
      File.read!(
        Path.join(
          File.cwd!(),
          "lib/casein/agents/preview_tools/control_session/pane_open.ex"
        )
      )

    refute pane_open =~ ~r/Process\.sleep\s*\(/,
           "pane_open must not sleep-poll (was 40×50ms = 2s)"
  end

  test "open_web_link_preview handle_event returns before the HTTP probe" do
    previous = Application.get_env(:casein, :embeddability_checker)
    Application.put_env(:casein, :embeddability_checker, __MODULE__.RaiseIfCalled)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:casein, :embeddability_checker),
        else: Application.put_env(:casein, :embeddability_checker, previous)
    end)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        workspace: %Workspace{id: "ws-1", name: "alpha"},
        tmux_session: "casein_alpha_u-dev"
      }
    }

    {us, result} =
      :timer.tc(fn ->
        TerminalEvents.handle_event(
          "terminal:open_web_link_preview",
          %{"url" => "https://example.com/x"},
          socket
        )
      end)

    assert {:noreply, ^socket, {:continue, {:open_web_link_preview, "https://example.com/x"}}} =
             result

    # BEFORE: embeddability HTTP sat in handle_event (up to 1.5s timeout).
    # AFTER: event replies without invoking the probe (RaiseIfCalled would explode).
    assert us < 50_000

    {total, ranked} = LiveDiffMeasure.rank_changed(socket.assigns, socket.assigns.__changed__)

    assert is_integer(total)
    assert is_list(ranked)
  end

  defmodule RaiseIfCalled do
    def frame_blocked_url?(_url), do: raise("embed probe must not run in handle_event")
    def frame_blocked_url?(_url, _opts), do: raise("embed probe must not run in handle_event")
  end
end
