defmodule DevIdeWeb.TerminalSurfaceTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DevIdeWeb.TerminalSurface
  alias DevIdeWeb.TerminalSurface.Pane

  defp render_surface(assigns) do
    html =
      render_component(&TerminalSurface.pane_layout/1, %{
        layout: Map.fetch!(assigns, :layout),
        panes: Map.get(assigns, :panes, %{}),
        focused_pane_id: Map.get(assigns, :focused_pane_id, "pane-1"),
        host_id: Map.get(assigns, :host_id, "local"),
        workspace_id: Map.get(assigns, :workspace_id, "ws-1"),
        equalize_flash: Map.get(assigns, :equalize_flash)
      })

    LazyHTML.from_fragment(html)
  end

  defp count(document, selector), do: document |> LazyHTML.query(selector) |> Enum.count()

  describe "pane rendering" do
    test "terminal autofocus is hook-driven instead of a native autofocus attribute" do
      html =
        render_component(DevIdeWeb.GhosttyTerminalComponent,
          id: "ghostty-pane-1",
          term: nil,
          autofocus: true
        )

      document = LazyHTML.from_fragment(html)
      terminal = LazyHTML.query(document, "#ghostty-pane-1")
      input = LazyHTML.query(document, "textarea[data-ghostty-input='true']")

      assert LazyHTML.attribute(terminal, "data-autofocus") == ["true"]
      assert LazyHTML.attribute(input, "autofocus") == []
    end

    test "renders a loading pane with stable focus wrapper attributes" do
      document =
        render_surface(%{
          layout: {:pane, "pane-1"},
          panes: %{"pane-1" => %Pane{}}
        })

      assert count(document, "#pane-wrapper-pane-1") == 1

      wrapper = LazyHTML.query(document, "#pane-wrapper-pane-1")
      assert LazyHTML.attribute(wrapper, "phx-click") == ["focus_pane"]
      assert LazyHTML.attribute(wrapper, "phx-value-pane-id") == ["pane-1"]
      assert LazyHTML.attribute(wrapper, "data-host-id") == ["local"]
      assert LazyHTML.attribute(wrapper, "data-workspace-id") == ["ws-1"]
      assert LazyHTML.attribute(wrapper, "data-session-sid") == []
      assert LazyHTML.text(document) =~ "starting terminal"
    end

    test "renders pane session metadata for pending raw launcher handoff" do
      document =
        render_surface(%{
          layout: {:pane, "pane-1"},
          panes: %{"pane-1" => %Pane{session_sid: "u-dev-tab"}}
        })

      wrapper = LazyHTML.query(document, "#pane-wrapper-pane-1")
      assert LazyHTML.attribute(wrapper, "data-workspace-id") == ["ws-1"]
      assert LazyHTML.attribute(wrapper, "data-session-sid") == ["u-dev-tab"]
    end

    test "renders pane error state with retry action" do
      document =
        render_surface(%{
          layout: {:pane, "pane-1"},
          panes: %{"pane-1" => %Pane{error: {:start_failed, :enoent}}}
        })

      assert count(document, ~s(button[phx-click="retry_pane"][phx-value-pane-id="pane-1"])) == 1
      assert LazyHTML.text(document) =~ "Terminal failed to start"
    end

    test "formats backend exit-status tuples without leaking raw Erlang terms" do
      document =
        render_surface(%{
          layout: {:pane, "pane-1"},
          panes: %{"pane-1" => %Pane{error: {:exit_status, 256}}}
        })

      text = LazyHTML.text(document)

      assert text =~ "Shell exited"
      assert text =~ "exit status 256"
      refute text =~ "{:exit_status, 256}"
    end

    test "panes render without the legacy floating control overlay" do
      # Pane verbs (split / zoom / close) live in the workspace header and
      # mobile keybar now and operate on real tmux panes — the per-pane
      # floating toolbar (and the LiveView split layout) was removed.
      document =
        render_surface(%{
          layout: {:pane, "pane-1"},
          panes: %{"pane-1" => %Pane{}},
          focused_pane_id: "pane-1"
        })

      assert count(document, ~s(button[phx-click="split_right"])) == 0
      assert count(document, ~s(button[phx-click="split_down"])) == 0
      assert count(document, ~s(button[phx-click="zoom_pane"])) == 0
      assert count(document, ~s(button[phx-click="close_pane"])) == 0
    end
  end
end
