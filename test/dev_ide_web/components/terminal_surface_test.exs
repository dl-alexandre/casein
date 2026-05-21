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
        pane_count: Map.get(assigns, :pane_count, 1),
        host_id: Map.get(assigns, :host_id, "local"),
        equalize_flash: Map.get(assigns, :equalize_flash)
      })

    LazyHTML.from_fragment(html)
  end

  defp count(document, selector), do: document |> LazyHTML.query(selector) |> Enum.count()

  describe "pane rendering" do
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
      assert LazyHTML.text(document) =~ "starting terminal"
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

    test "renders focused pane controls only for the focused pane" do
      document =
        render_surface(%{
          layout: {:split, :horizontal, [{:pane, "pane-1"}, {:pane, "pane-2"}], [0.5, 0.5]},
          panes: %{"pane-1" => %Pane{}, "pane-2" => %Pane{}},
          focused_pane_id: "pane-2",
          pane_count: 2
        })

      pane_one = LazyHTML.query(document, "#pane-wrapper-pane-1")
      pane_two = LazyHTML.query(document, "#pane-wrapper-pane-2")

      assert count(pane_one, ~s(button[phx-click="split_right"])) == 0
      assert count(pane_two, ~s(button[phx-click="split_right"])) == 1
      assert count(pane_two, ~s(button[phx-click="split_down"])) == 1
      assert count(pane_two, ~s(button[phx-click="close_pane"][phx-value-pane-id="pane-2"])) == 1
    end
  end

  describe "split chrome" do
    test "renders resizer hook with stable ids and quiet visual classes" do
      document =
        render_surface(%{
          layout: {:split, :vertical, [{:pane, "top"}, {:pane, "bottom"}], [0.4, 0.6]},
          panes: %{"top" => %Pane{}, "bottom" => %Pane{}},
          focused_pane_id: "top",
          pane_count: 2
        })

      resizer = LazyHTML.query(document, "#split-resizer-top-bottom")

      assert count(document, "#split-resizer-top-bottom") == 1
      assert LazyHTML.attribute(resizer, "phx-hook") == ["SplitResizer"]
      assert LazyHTML.attribute(resizer, "data-direction") == ["vertical"]
      assert LazyHTML.attribute(resizer, "data-left") == ["top"]
      assert LazyHTML.attribute(resizer, "data-right") == ["bottom"]
      assert LazyHTML.attribute(resizer, "role") == ["separator"]
      assert LazyHTML.attribute(resizer, "aria-orientation") == ["horizontal"]

      class = resizer |> LazyHTML.attribute("class") |> Enum.join(" ")
      assert class =~ "bg-transparent"
      refute class =~ "bg-zinc-700"
    end
  end
end
