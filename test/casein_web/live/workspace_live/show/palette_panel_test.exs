defmodule CaseinWeb.WorkspaceLive.Show.PalettePanelTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CaseinWeb.WorkspaceLive.Show.PalettePanel

  defp item(opts) do
    Map.merge(
      %{
        id: "item-1",
        kind: :action,
        label: "Zoom pane",
        detail: "some detail",
        hint: "z"
      },
      Map.new(opts)
    )
  end

  defp render_open(opts \\ []) do
    items = Keyword.get(opts, :items, [item([])])
    category = Keyword.get(opts, :category, :tmux)

    render_component(&PalettePanel.palette_overlay/1, %{
      palette_open: true,
      palette_query: "",
      palette_items: items,
      palette_selected_idx: 0,
      palette_category: category
    })
  end

  test "keeps phx-mounted focus on the query input" do
    html = render_open()
    assert html =~ ~s(id="palette-query")
    assert html =~ "phx-mounted"
  end

  test "renders every category button so PaletteHook Tab cycling stays reachable" do
    html = render_open(category: :files)

    for cat <- PalettePanel.palette_categories() do
      assert html =~ ~s(phx-value-category="#{cat}")
      assert html =~ PalettePanel.palette_category_label(cat)
    end
  end

  test "collapses inactive categories only below sm (width), not via pointer-coarse" do
    html = render_open(category: :files)

    # Active tab stays visible at every width.
    assert html =~ ~s(bg-primary/20 text-base-content)

    # Inactive tabs carry max-sm:hidden — visual collapse only; buttons remain.
    assert html =~ "max-sm:hidden"
    refute html =~ "pointer-coarse:hidden"
  end

  test "drops kind and detail on narrow rows; keeps label and hint" do
    html =
      render_open(
        items: [
          item(id: "a", label: "Open file", detail: "path/to/file.ex", hint: "↵")
        ]
      )

    assert html =~ "Open file"
    assert html =~ "↵"
    assert html =~ ~r/max-sm:hidden[^>]*>\s*action/
    assert html =~ ~r/max-sm:hidden[^>]*>path\/to\/file\.ex/
  end

  test "uses adaptive top offset instead of fixed pt-24 alone" do
    html = render_open()
    assert html =~ "pt-[max(0.5rem,min(6rem,10svh))]"
    assert html =~ "sm:pt-16"
    assert html =~ "md:pt-24"
    # Bare fixed pt-24 (pre-fix) must not remain; md:pt-24 is fine.
    refute html =~ ~r/[^:\w]pt-24/
  end

  test "sizes row and tab hit targets with pointer-coarse, not width" do
    html = render_open()
    assert html =~ "pointer-coarse:min-h-11"
    assert html =~ "pointer-coarse:py-3"
    # Footer keyboard hints remain on desktop (sm+); not removed.
    assert html =~ "hidden items-center gap-2 sm:flex"
    assert html =~ "navigate"
    assert html =~ "category"
  end

  test "closed palette keeps the empty anchor" do
    html =
      render_component(&PalettePanel.palette_overlay/1, %{
        palette_open: false,
        palette_query: "",
        palette_items: [],
        palette_selected_idx: 0,
        palette_category: :all
      })

    assert html =~ ~s(id="palette-modal-empty")
  end
end
