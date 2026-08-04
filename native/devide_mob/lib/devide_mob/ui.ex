defmodule DevideMob.UI do
  @moduledoc """
  The component kit every DevideMob product screen renders through.

  It exists because Mob's view tree is raw data: without a shared vocabulary
  each screen re-invents its own paddings, chip shapes and button weights, and
  the app drifts into a pile of grey rectangles. Everything here is a plain
  `%{type:, props:, children:}` map, so it composes with hand-written nodes and
  stays testable with `Mob.ScreenCase`.

  ## Native constraints this kit encodes

  Three renderer facts drive most of the API — get them wrong and the layout
  looks fine in a unit test and wrong on the device:

    * **`gap:` is a no-op.** SwiftUI renders `VStack(spacing: 0)` and Compose a
      bare `Column`; neither reads the prop. Vertical and horizontal rhythm has
      to come from real `Spacer` nodes — `stack/2` and `row/2` insert them.

    * **Only `Box` and `Button` round their corners.** On iOS `corner_radius`
      and `border_*` are applied by `MobBox` and `Button.clipShape` only, so a
      `Column` with a radius renders square. `card/2` and `tinted/3` are boxes.

    * **A `Box` fills its parent's width** unless given an explicit `width`.
      Content-hugging pills therefore ride on `Button` (`fill_width: false`,
      `compact: true`), which hugs on both platforms.

  ## Tones

  Status color is a *tone*, not a theme token: `:accent`, `:attention`,
  `:running`, `:failed`, `:done`, `:neutral`. Each resolves to a foreground and
  a translucent tint of the same hue, so a chip, a dot and a banner describing
  the same state always agree.
  """

  # ── Tones ────────────────────────────────────────────────────────────────
  # {foreground, tint}. Tints are the same hue at ~18% alpha so they sit on
  # either surface without a second palette.
  @tones %{
    accent: {0xFF9E9CFF, 0x2E605DFF},
    attention: {0xFFFFC14D, 0x2EFFB020},
    running: {0xFF6FB8FF, 0x2E3D8BFF},
    failed: {0xFFFF7A92, 0x2EFF5470},
    done: {0xFF4FD6B4, 0x2E2DD4A7},
    neutral: {0xFF8A94A2, 0x1FFFFFFF}
  }

  @doc "Foreground color for a tone."
  @spec tone_fg(atom()) :: non_neg_integer()
  def tone_fg(tone), do: @tones |> Map.get(tone, @tones.neutral) |> elem(0)

  @doc "Translucent background tint for a tone."
  @spec tone_tint(atom()) :: non_neg_integer()
  def tone_tint(tone), do: @tones |> Map.get(tone, @tones.neutral) |> elem(1)

  # ── Layout ───────────────────────────────────────────────────────────────

  @doc "A fixed spacer. The only spacing primitive the native renderers honor."
  def gap(size), do: %{type: :spacer, props: %{size: size}, children: []}

  @doc """
  A column with `size` points between children. `nil` children are dropped
  first, so callers can inline conditionals without leaving double gaps.
  """
  def stack(children, opts \\ []) do
    %{
      type: :column,
      props: layout_props(opts),
      children: interleave(children, Keyword.get(opts, :gap, 12))
    }
  end

  @doc "A row with `size` points between children. Drops `nil` children."
  def row(children, opts \\ []) do
    %{
      type: :row,
      props: layout_props(opts),
      children: interleave(children, Keyword.get(opts, :gap, 8))
    }
  end

  defp interleave(children, size) do
    children
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.intersperse(gap(size))
  end

  defp layout_props(opts) do
    opts
    |> Keyword.drop([:gap])
    |> Keyword.put_new(:fill_width, true)
    |> Map.new()
  end

  # ── Surfaces ─────────────────────────────────────────────────────────────

  @doc """
  The standard content surface: rounded, hairline-bordered, padded.

  Pass `on_tap:` to make the whole card tappable, `tone:` to tint its border
  (how a card signals urgency without shouting).
  """
  def card(children, opts \\ []) do
    tone = Keyword.get(opts, :tone)

    box(
      [
        stack(List.wrap(children), gap: Keyword.get(opts, :gap, 10))
      ],
      opts
      |> Keyword.drop([:tone, :gap])
      |> Keyword.merge(
        background: Keyword.get(opts, :background, :surface),
        corner_radius: :radius_lg,
        border_color: if(tone, do: tone_tint(tone), else: :border),
        border_width: 1.0,
        padding: Keyword.get(opts, :padding, 14)
      )
    )
  end

  @doc "A tinted panel — banners, callouts, inline notices."
  def tinted(children, tone, opts \\ []) do
    box(
      [stack(List.wrap(children), gap: Keyword.get(opts, :gap, 4))],
      Keyword.merge(opts,
        background: tone_tint(tone),
        corner_radius: :radius_md,
        border_color: tone_tint(tone),
        border_width: 1.0,
        padding: Keyword.get(opts, :padding, 12)
      )
    )
  end

  @doc "A bare rounded box. `children` are stacked (z-order), not flowed."
  def box(children, opts \\ []) do
    %{type: :box, props: Map.new(opts), children: List.wrap(children)}
  end

  @doc "Hairline rule."
  def divider, do: %{type: :divider, props: %{color: :border}, children: []}

  # ── Typography ───────────────────────────────────────────────────────────

  @doc "Screen title."
  def screen_title(text),
    do: text(text, text_size: :"2xl", font_weight: "bold", text_color: :on_background)

  @doc "Card / section heading."
  def title(text, opts \\ []),
    do:
      text(
        text,
        Keyword.merge([text_size: :lg, font_weight: "semibold", text_color: :on_surface], opts)
      )

  @doc "Body copy."
  def body(text, opts \\ []),
    do: text(text, Keyword.merge([text_size: :sm, text_color: :on_surface], opts))

  @doc "Secondary line — timestamps, workspace ids, counts."
  def meta(text, opts \\ []),
    do: text(text, Keyword.merge([text_size: :xs, text_color: :muted], opts))

  @doc """
  Small section label. Wide-tracked rather than upper-cased: the copy stays
  exactly as written (screen readers and tests read the same string).
  """
  def section_label(text),
    do:
      text(text,
        text_size: :xs,
        text_color: :muted,
        font_weight: "semibold",
        letter_spacing: 0.8
      )

  @doc "A raw text node. `nil` / empty text renders nothing, so callers can inline it."
  def text(text, opts \\ [])
  def text(nil, _opts), do: nil
  def text("", _opts), do: nil

  def text(text, opts) do
    %{type: :text, props: opts |> Map.new() |> Map.put(:text, text), children: []}
  end

  # ── Atoms ────────────────────────────────────────────────────────────────

  @doc """
  A content-hugging status tag: tinted background, tone-colored label.

  It is a `Text` node, not a `Box` or `Button`. A `Box` would stretch to the
  full row width (it has no content-hugging mode) and a `Button` would announce
  itself as tappable to screen readers and disappear from text queries. The
  cost is that `corner_radius` only lands on Android — on iOS a `Text`
  background draws square. Use `button/4` when the tag is genuinely tappable
  (a failed status that retries, say); that one is a pill on both platforms.
  """
  def chip(label, tone \\ :neutral, opts \\ []) do
    %{
      type: :text,
      props:
        %{
          text: to_string(label),
          background: Keyword.get(opts, :background, tone_tint(tone)),
          text_color: Keyword.get(opts, :text_color, tone_fg(tone)),
          text_size: :xs,
          font_weight: "medium",
          corner_radius: :radius_pill,
          padding_left: 10,
          padding_right: 10,
          padding_top: 5,
          padding_bottom: 5
        }
        |> maybe_put(:on_tap, Keyword.get(opts, :on_tap)),
      children: []
    }
  end

  @doc "An 8pt status dot."
  def dot(tone) do
    box([],
      width: 8.0,
      height: 8.0,
      corner_radius: :radius_pill,
      background: tone_fg(tone)
    )
  end

  @doc "A logical icon glyph (SF Symbol on iOS, Material on Android)."
  def icon(name, opts \\ []) do
    %{
      type: :icon,
      props:
        opts
        |> Keyword.merge(name: name)
        |> Keyword.put_new(:text_size, 16)
        |> Keyword.put_new(:text_color, :muted)
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new(),
      children: []
    }
  end

  @doc "An indeterminate spinner."
  def spinner, do: %{type: :progress, props: %{color: :primary}, children: []}

  # ── Buttons ──────────────────────────────────────────────────────────────

  @doc """
  A button in one of four weights: `:primary`, `:secondary`, `:ghost`,
  `:danger`. Every variant is 44pt tall (the platform minimum tap target).

  Labels are truncated to one line by both renderers, so keep them to a word
  or two.
  """
  def button(label, tap, variant \\ :primary, opts \\ []) do
    disabled? = Keyword.get(opts, :disabled, false)
    {bg, fg, border} = if disabled?, do: disabled_colors(), else: variant_colors(variant)

    props =
      %{
        text: label,
        background: bg,
        text_color: fg,
        text_size: :sm,
        font_weight: "semibold",
        corner_radius: :radius_md,
        padding_left: 14,
        padding_right: 14,
        height: 44.0,
        fill_width: Keyword.get(opts, :fill_width, true),
        disabled: disabled?
      }
      |> maybe_put(:weight, Keyword.get(opts, :weight))
      |> maybe_put(:border_color, border)
      |> maybe_put(:border_width, border && 1.0)
      # NEITHER renderer reads `disabled` — not `MobBridge.kt`, not
      # `MobRootView.swift` — so a "disabled" button with an `on_tap` is still
      # fully tappable on device. The prop is kept for tests and future
      # renderer support, but the actual guarantee comes from withholding the
      # tap and dimming the colors here.
      |> maybe_put(:on_tap, unless(disabled?, do: tap))

    %{type: :button, props: props, children: []}
  end

  @doc """
  A square 44pt icon button — header actions, overflow menus.

  `label:` becomes the icon's accessibility label (VoiceOver on iOS,
  contentDescription on Android); an icon-only control without one is
  unusable with a screen reader.
  """
  def icon_button(icon_name, tap, opts \\ []) do
    box(
      [
        icon(icon_name,
          text_size: 18,
          text_color: Keyword.get(opts, :text_color, :on_surface),
          text: Keyword.get(opts, :label)
        )
      ],
      align: "center",
      width: 44.0,
      height: 44.0,
      corner_radius: :radius_md,
      background: Keyword.get(opts, :background, :surface_raised),
      on_tap: tap
    )
  end

  # Dimmed, and readable as "not available" without relying on native opacity.
  defp disabled_colors, do: {:surface, :muted, :border}

  defp variant_colors(:primary), do: {:primary, :on_primary, nil}
  defp variant_colors(:secondary), do: {:surface_raised, :on_surface, nil}
  defp variant_colors(:ghost), do: {0x00000000, :on_surface, :border}
  defp variant_colors(:danger), do: {tone_tint(:failed), tone_fg(:failed), nil}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ── Composites ───────────────────────────────────────────────────────────

  @doc """
  A screen header: title, optional subtitle, optional trailing actions.

  Sits on the page background (not a colored bar) so the content below is what
  carries color.
  """
  def header(title, opts \\ []) do
    actions = opts |> Keyword.get(:actions, []) |> Enum.reject(&is_nil/1)
    leading = Keyword.get(opts, :leading)

    stack(
      [
        row(
          [
            leading,
            # NB: no `weight` on the title itself. `weight` is axis-relative —
            # in this Column it would be a VERTICAL weight, and Compose duly
            # stretched the title to the full screen height, pushing the
            # subtitle to the bottom edge. The weight belongs on this stack,
            # which is the Row child that should flex horizontally.
            stack(
              [
                text(title,
                  text_size: :"2xl",
                  font_weight: "bold",
                  text_color: :on_background
                ),
                meta(Keyword.get(opts, :subtitle))
              ],
              gap: 2,
              weight: 1
            )
          ] ++ actions,
          gap: 8
        ),
        divider()
      ],
      gap: 12,
      padding_left: 16,
      padding_right: 16,
      padding_top: 12
    )
  end

  @doc """
  A full-bleed empty state: headline, explanation, one call to action.
  """
  def empty_state(heading, copy, opts \\ []) do
    stack(
      [
        Keyword.get(opts, :icon) && icon(Keyword.get(opts, :icon), text_size: 28),
        title(heading, text_size: :lg),
        body(copy, text_color: :muted),
        Keyword.get(opts, :footnote) && meta(Keyword.get(opts, :footnote)),
        Keyword.get(opts, :cta) &&
          button(Keyword.get(opts, :cta), Keyword.get(opts, :on_tap), :primary)
      ],
      gap: 10,
      padding: 20
    )
  end

  @doc "A label/value row — the workhorse of detail screens."
  def field(label, value) do
    row(
      [
        meta(label, weight: 1),
        body(value, text_align: :right, weight: 1)
      ],
      gap: 8
    )
  end
end
