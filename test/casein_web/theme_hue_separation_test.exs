defmodule CaseinWeb.ThemeHueSeparationTest do
  use ExUnit.Case, async: true

  @css_path "assets/css/app.css"

  # Categorical hue floor: a 12-step colour wheel is 30°/step; skip-a-step
  # (Ware / ColorBrewer) is the usual "these are different categories" gap.
  # WCAG 1.4.1 (Use of Color) does not publish a degree number, but 27° on
  # the warm arc is exactly the collision deuteranomaly collapses — selection
  # and warning both read as amber. #950.
  #
  # This is not WCAG 1.4.11 (3:1 of a control against its background). Adjacent
  # chips of similar lightness will never hit 3:1 against each other; the
  # distinction at chip scale is hue. Do not "pass" this by pumping
  # status-warning chroma — that token is caution language on banners, dirty,
  # stalled, and approvals, and must stay put.
  @min_attention_hue_degrees 60.0

  # Selection must not land on ok / danger / live either (#950). Dark already
  # sits 47° from live (hue 230) and ~18° from idle (hue 295); idle is quiet
  # chrome, not attention, so it is not in this set. 40° keeps the dark pairing
  # legal while still rejecting a primary that reads as those statuses.
  @min_status_hue_degrees 40.0

  # Proven #950 before-state. Light Phoenix orange vs status-warning. A
  # regression that restores this pair must fail the live-token assertions.
  @legacy_light_primary_hue 47.604
  @legacy_light_warning_hue 75.0

  test "legacy light primary vs warning sits below the categorical floor" do
    distance = hue_distance(@legacy_light_primary_hue, @legacy_light_warning_hue)

    assert_in_delta distance, 27.4, 0.05

    assert distance < @min_attention_hue_degrees,
           "legacy pair is the failing fixture (#{Float.round(distance, 1)}°); " <>
             "if this passes, the floor was lowered"
  end

  test "light primary stays off the warning/danger warm arc" do
    css = File.read!(@css_path)
    primary = plugin_hue(css, "light", "--color-primary")
    warning = first_oklch_hue(css, "--casein-status-warning")
    danger = first_oklch_hue(css, "--casein-status-danger")

    assert_attention_separation("light", :warning, primary, warning)
    assert_attention_separation("light", :danger, primary, danger)
  end

  test "dark primary stays off the warning/danger warm arc" do
    css = File.read!(@css_path)
    primary = plugin_hue(css, "dark", "--color-primary")
    warning = dark_status_hue(css, "--casein-status-warning")
    danger = dark_status_hue(css, "--casein-status-danger")

    assert_attention_separation("dark", :warning, primary, warning)
    assert_attention_separation("dark", :danger, primary, danger)
  end

  test "primary does not land on ok/danger/live in either theme" do
    css = File.read!(@css_path)

    for {theme, primary, statuses} <- [
          {"light", plugin_hue(css, "light", "--color-primary"),
           %{
             ok: first_oklch_hue(css, "--casein-status-ok"),
             danger: first_oklch_hue(css, "--casein-status-danger"),
             live: first_oklch_hue(css, "--casein-status-live")
           }},
          {"dark", plugin_hue(css, "dark", "--color-primary"),
           %{
             ok: dark_status_hue(css, "--casein-status-ok"),
             danger: dark_status_hue(css, "--casein-status-danger"),
             live: dark_status_hue(css, "--casein-status-live")
           }}
        ] do
      Enum.each(statuses, fn {name, hue} ->
        distance = hue_distance(primary, hue)

        assert distance >= @min_status_hue_degrees,
               "#{theme} primary hue #{primary} vs status-#{name} #{hue} is " <>
                 "#{Float.round(distance, 1)}° (need ≥ #{@min_status_hue_degrees}°)"
      end)
    end
  end

  defp assert_attention_separation(theme, status, primary, status_hue) do
    distance = hue_distance(primary, status_hue)

    assert distance >= @min_attention_hue_degrees,
           "#{theme} primary hue #{primary} vs status-#{status} #{status_hue} is " <>
             "#{Float.round(distance, 1)}° (need ≥ #{@min_attention_hue_degrees}°). " <>
             "Move --color-primary off the warm arc; do not retune status-warning."
  end

  defp plugin_hue(css, theme, var) do
    block = plugin_block(css, theme)

    case oklch_hue(block, var) do
      nil -> flunk("missing #{var} in daisyUI #{theme} theme plugin")
      hue -> hue
    end
  end

  defp plugin_block(css, theme) do
    pattern =
      ~r/@plugin "\.\.\/vendor\/daisyui-theme" \{([^}]*name:\s*"#{theme}"[^}]*)\}/

    case Regex.run(pattern, css) do
      [_, block] -> block
      nil -> flunk("missing daisyUI theme plugin block name=#{theme}")
    end
  end

  defp first_oklch_hue(css, var) do
    case oklch_hue(css, var) do
      nil -> flunk("missing #{var} in #{@css_path}")
      hue -> hue
    end
  end

  defp dark_status_hue(css, var) do
    pattern = ~r/:root\[data-theme="dark"\] \{([^}]*)\}/

    case Regex.run(pattern, css) do
      [_, block] ->
        case oklch_hue(block, var) do
          nil -> flunk("missing #{var} in [data-theme=dark]")
          hue -> hue
        end

      nil ->
        flunk("missing :root[data-theme=dark] status block")
    end
  end

  defp oklch_hue(source, var) do
    pattern = ~r/#{Regex.escape(var)}:\s*oklch\(\s*[\d.]+%\s+[\d.]+\s+([\d.]+)\s*\)/

    case Regex.run(pattern, source) do
      [_, hue] ->
        {parsed, ""} = Float.parse(hue)
        parsed

      nil ->
        nil
    end
  end

  defp hue_distance(a, b) do
    delta = :math.fmod(abs(a - b), 360.0)
    min(delta, 360.0 - delta)
  end
end
