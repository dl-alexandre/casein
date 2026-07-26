defmodule CaseinWeb.WorkspaceLive.Show.TerminalStateExtraTest do
  # Pure-function coverage for TerminalState branches the primary test skips:
  # resize parsing, tmux-session-name derivation, session-aliveness adapter
  # dispatch, pane-data construction, and the remaining
  # next_ui_highlight_pane_id / selected_preview_pane arms. Everything here is
  # pure or driven through a swappable tmux adapter (no live IO/process state).
  use Casein.TestCase, async: false

  alias Casein.Terminals.Session.Info, as: SessionInfo
  alias CaseinWeb.WorkspaceLive.Show.TerminalState

  # ---------------------------------------------------------------------------
  # next_ui_highlight_pane_id/5 — the preview-on-prev-active "hold" arm and the
  # final fallback that the existing test does not drive.
  # ---------------------------------------------------------------------------
  describe "next_ui_highlight_pane_id/5 (additional arms)" do
    test "holds the current selection when leaving a preview pane (prev was a preview)" do
      # prev_active_pane is a preview, active moved off it, current != prev:
      # the highlight is held (not snapped to the new active pane).
      preview_panes = %{"%preview" => %{}}

      assert "%pinned" =
               TerminalState.next_ui_highlight_pane_id(
                 "%pinned",
                 "%shell",
                 "%preview",
                 preview_panes,
                 false
               )
    end

    test "snaps to the new active pane when current tracked it but prev was a preview is false path" do
      # prev_active_pane is NOT a preview, current == prev_active_pane, active
      # moved: follow tmux focus to the new active pane.
      assert "%new" =
               TerminalState.next_ui_highlight_pane_id(
                 "%old",
                 "%new",
                 "%old",
                 %{},
                 false
               )
    end

    test "falls through to current when nothing else matches" do
      # current set, not nil; active is not a preview; prev not a preview;
      # current != prev_active_pane; active == prev_active_pane -> fallback.
      assert "%pinned" =
               TerminalState.next_ui_highlight_pane_id(
                 "%pinned",
                 "%same",
                 "%same",
                 %{},
                 false
               )
    end

    test "highlights the active pane when it is itself a preview" do
      preview_panes = %{"%previewactive" => %{}}

      assert "%previewactive" =
               TerminalState.next_ui_highlight_pane_id(
                 "%pinned",
                 "%previewactive",
                 "%shell",
                 preview_panes,
                 false
               )
    end
  end

  # ---------------------------------------------------------------------------
  # selected_preview_pane — fallback clause (non-map preview_panes) and the
  # highlight-id branch.
  # ---------------------------------------------------------------------------
  describe "selected_preview_pane/6 (fallback + highlight branch)" do
    test "returns nil when preview_panes is not a map (fallback clause)" do
      assert TerminalState.selected_preview_pane(
               nil,
               "%preview",
               nil,
               [],
               "@1",
               "casein_alpha_u-alice"
             ) == nil
    end

    test "uses the highlight id when the selected id is nil" do
      windows = [
        %{id: "@1", active: true, pane_list: [%{id: "%preview"}]}
      ]

      preview_panes = %{
        "%preview" => %{
          pane_id: "%preview",
          title: "Live",
          display_url: "https://example.com/live",
          tmux_session: "casein_alpha_u-alice"
        }
      }

      assert %{title: "Live"} =
               TerminalState.selected_preview_pane(
                 preview_panes,
                 nil,
                 "%preview",
                 windows,
                 "@1",
                 "casein_alpha_u-alice"
               )
    end

    test "matches a preview that carries no tmux_session (session-agnostic)" do
      windows = [%{id: "@1", active: true, pane_list: [%{id: "%preview"}]}]

      preview_panes = %{
        "%preview" => %{pane_id: "%preview", title: "NoSession"}
      }

      assert %{title: "NoSession"} =
               TerminalState.selected_preview_pane(
                 preview_panes,
                 "%preview",
                 nil,
                 windows,
                 "@1",
                 "casein_alpha_u-alice"
               )
    end

    test "returns nil when the active window id is not a binary (panes_for_window fallback)" do
      preview_panes = %{"%preview" => %{pane_id: "%preview", title: "X"}}

      assert TerminalState.selected_preview_pane(
               preview_panes,
               "%preview",
               nil,
               [%{id: "@1", pane_list: [%{id: "%preview"}]}],
               nil,
               "casein_alpha_u-alice"
             ) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # parse_resize_amount/1 — all clauses.
  # ---------------------------------------------------------------------------
  describe "parse_resize_amount/1" do
    test "nil yields the default amount" do
      assert {:ok, 5} = TerminalState.parse_resize_amount(nil)
    end

    test "valid numeric string within range" do
      assert {:ok, 7} = TerminalState.parse_resize_amount("7")
    end

    test "string above the max is rejected" do
      assert {:error, :invalid_amount} = TerminalState.parse_resize_amount("51")
    end

    test "string exactly at the max is accepted" do
      assert {:ok, 50} = TerminalState.parse_resize_amount("50")
    end

    test "non-numeric / trailing-garbage strings are rejected" do
      assert {:error, :invalid_amount} = TerminalState.parse_resize_amount("12x")
      assert {:error, :invalid_amount} = TerminalState.parse_resize_amount("abc")
    end

    test "zero and negative strings are rejected (guard integer > 0)" do
      assert {:error, :invalid_amount} = TerminalState.parse_resize_amount("0")
      assert {:error, :invalid_amount} = TerminalState.parse_resize_amount("-3")
    end

    test "positive integer within range" do
      assert {:ok, 10} = TerminalState.parse_resize_amount(10)
    end

    test "integer above the max is rejected" do
      assert {:error, :invalid_amount} = TerminalState.parse_resize_amount(999)
    end

    test "non-positive integer falls to the catch-all clause" do
      assert {:error, :invalid_amount} = TerminalState.parse_resize_amount(0)
      assert {:error, :invalid_amount} = TerminalState.parse_resize_amount(-1)
    end

    test "unsupported types fall to the catch-all clause" do
      assert {:error, :invalid_amount} = TerminalState.parse_resize_amount(:weird)
      assert {:error, :invalid_amount} = TerminalState.parse_resize_amount(%{})
    end
  end

  # ---------------------------------------------------------------------------
  # tmux_session_for_info/2 — all four clauses.
  # ---------------------------------------------------------------------------
  describe "tmux_session_for_info/2" do
    test "shell with explicit non-empty tmux_session returns it verbatim" do
      info = %SessionInfo{kind: :shell, sid: "s1", tmux_session: "casein_explicit"}
      assert TerminalState.tmux_session_for_info(info, "ws") == "casein_explicit"
    end

    test "shell with blank tmux_session derives the name from workspace + sid" do
      # Tmux.session_name/2 -> "casein_<sanitized ws>_<sanitized sid>"
      info = %SessionInfo{kind: :shell, sid: "my sid", tmux_session: ""}
      assert TerminalState.tmux_session_for_info(info, "My WS") == "casein_My_WS_my_sid"
    end

    test "shell with nil tmux_session derives the name from workspace + sid" do
      info = %SessionInfo{kind: :shell, sid: "abc", tmux_session: nil}
      assert TerminalState.tmux_session_for_info(info, "alpha") == "casein_alpha_abc"
    end

    test "non-shell session with an explicit tmux_session returns it" do
      info = %SessionInfo{kind: :agent, tmux_session: "casein_agent_sess"}
      assert TerminalState.tmux_session_for_info(info, "ws") == "casein_agent_sess"
    end

    test "non-shell session with no tmux_session returns nil" do
      info = %SessionInfo{kind: :agent, tmux_session: nil}
      assert TerminalState.tmux_session_for_info(info, "ws") == nil
    end

    test "shell with neither tmux_session nor sid falls through to nil" do
      info = %SessionInfo{kind: :shell, sid: nil, tmux_session: nil}
      assert TerminalState.tmux_session_for_info(info, "ws") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # primary_pane_data/2 — exact shape of the seeded pane map.
  # ---------------------------------------------------------------------------
  describe "primary_pane_data/2" do
    test "builds the single pane-1 entry with the session/tmux ids and defaults" do
      data = TerminalState.primary_pane_data("sid-9", "casein_ws_sid-9")

      assert %{
               "pane-1" => %{
                 ghostty_term: nil,
                 ghostty_pty: nil,
                 worker: nil,
                 backend: nil,
                 session_sid: "sid-9",
                 tmux_session: "casein_ws_sid-9",
                 cols: 120,
                 rows: 40,
                 error: nil,
                 auto_retry_count: 0
               }
             } = data

      assert map_size(data) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # tmux_session_alive?/1 — adapter dispatch (binary), non-binary, and the
  # rescue path. Driven through a configurable tmux adapter stub.
  # ---------------------------------------------------------------------------
  describe "tmux_session_alive?/1" do
    setup do
      prev = Application.get_env(:casein, :tmux_adapter)

      on_exit(fn ->
        if prev do
          Application.put_env(:casein, :tmux_adapter, prev)
        else
          Application.delete_env(:casein, :tmux_adapter)
        end
      end)

      :ok
    end

    test "non-binary session is never alive" do
      assert TerminalState.tmux_session_alive?(nil) == false
      assert TerminalState.tmux_session_alive?(:atom) == false
    end

    test "delegates to the adapter's session_alive?/1 when exported (true)" do
      Application.put_env(:casein, :tmux_adapter, __MODULE__.AliveAdapter)
      assert TerminalState.tmux_session_alive?("casein_x") == true
    end

    test "delegates to the adapter's session_alive?/1 when exported (false)" do
      Application.put_env(:casein, :tmux_adapter, __MODULE__.DeadAdapter)
      assert TerminalState.tmux_session_alive?("casein_x") == false
    end

    test "assumes alive when the adapter does not export session_alive?/1" do
      Application.put_env(:casein, :tmux_adapter, __MODULE__.NoAliveCheckAdapter)
      assert TerminalState.tmux_session_alive?("casein_x") == true
    end

    test "a raising adapter is treated as not alive (rescue path)" do
      Application.put_env(:casein, :tmux_adapter, __MODULE__.RaisingAdapter)
      assert TerminalState.tmux_session_alive?("casein_x") == false
    end
  end

  # ---------------------------------------------------------------------------
  # tmux_adapter/0 — default + override.
  # ---------------------------------------------------------------------------
  describe "tmux_adapter/0" do
    test "returns the configured adapter, defaulting to Tmux" do
      prev = Application.get_env(:casein, :tmux_adapter)
      Application.delete_env(:casein, :tmux_adapter)

      try do
        assert TerminalState.tmux_adapter() == Casein.Terminals.Tmux
      after
        if prev, do: Application.put_env(:casein, :tmux_adapter, prev)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # tmux_mutations_allowed?/1 — assign-driven boolean.
  # ---------------------------------------------------------------------------
  describe "tmux_mutations_allowed?/1" do
    test "true only when the assign is exactly true" do
      assert TerminalState.tmux_mutations_allowed?(%{assigns: %{tmux_mutations_enabled?: true}})
    end

    test "false when the assign is false, missing, or truthy-but-not-true" do
      refute TerminalState.tmux_mutations_allowed?(%{assigns: %{tmux_mutations_enabled?: false}})
      refute TerminalState.tmux_mutations_allowed?(%{assigns: %{}})
      refute TerminalState.tmux_mutations_allowed?(%{assigns: %{tmux_mutations_enabled?: :yes}})
    end
  end

  # Stub adapters: exercise the function_exported?/rescue branches of
  # tmux_session_alive?/1 without touching real tmux.
  defmodule AliveAdapter do
    def session_alive?(_session), do: true
  end

  defmodule DeadAdapter do
    def session_alive?(_session), do: false
  end

  defmodule NoAliveCheckAdapter do
    # Intentionally exports no session_alive?/1.
    def noop, do: :ok
  end

  defmodule RaisingAdapter do
    def session_alive?(_session), do: raise("boom")
  end
end
