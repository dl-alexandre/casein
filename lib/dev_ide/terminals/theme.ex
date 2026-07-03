defmodule DevIDE.Terminals.Theme do
  @moduledoc """
  Renderer-first terminal themes for DevIDE raw Ghostty panes.

  Loads optional Ghostty-style `ghostty.conf` files (e.g. omarchy theme exports),
  falls back to built-in Catppuccin Mocha/Latte presets, and supplies:

  * a JSON-safe client bundle for the browser LUT + CSS chrome vars
  * OSC 10/11/12/4 rewrite helpers for `PaneWorker` query responses
  """

  @type scheme :: :dark | :light
  @type rgb :: {byte(), byte(), byte()}

  alias DevIDE.Terminals.Theme.Builtins

  defstruct [:id, :chrome, :palette, :background, :foreground, :cursor]

  @osc_color ~r/\e\](10|11|12)(?:;[^\a\x1b]*)?(\a|\e\\)/
  @osc_palette ~r/\e\]4;(\d{1,3})(?:;[^\a\x1b]*)?(\a|\e\\)/

  @preset_ids Builtins.ids() ++ ["system"]
  @default_scheme :dark
  @default_preset_id "catppuccin"

  @doc "Palette-selectable preset ids. The browser chooses the light/dark variant."
  @spec preset_ids() :: [String.t()]
  def preset_ids, do: @preset_ids

  @spec default_scheme() :: scheme()
  def default_scheme, do: @default_scheme

  @spec default_preset_id() :: String.t()
  def default_preset_id, do: @default_preset_id

  @spec valid_preset?(String.t()) :: boolean()
  def valid_preset?(id) when is_binary(id), do: id in @preset_ids
  def valid_preset?(_), do: false

  @spec list_presets() :: [map()]
  def list_presets do
    Builtins.list() ++
      [
        %{
          id: "system",
          label: "System theme file",
          detail: "ghostty.conf / omarchy export when present — follows system appearance"
        }
      ]
  end

  @doc "Returns `%{dark: theme, light: theme, sources: ..., preset: id}`."
  @spec load_bundle(String.t()) :: map()
  def load_bundle(preset_id \\ @default_preset_id) do
    preset_id = normalize_preset_id(preset_id)

    %{
      preset: preset_id,
      dark: load_for_scheme(:dark, preset_id),
      light: load_for_scheme(:light, preset_id),
      sources: %{
        dark: if(preset_id == "system", do: first_existing_path(:dark), else: nil),
        light: if(preset_id == "system", do: first_existing_path(:light), else: nil)
      }
    }
  end

  @doc "JSON-safe map for LiveView / JS (`preset`, `dark`, `light`, optional `sources`)."
  @spec client_bundle(String.t()) :: map()
  def client_bundle(preset_id \\ @default_preset_id) do
    bundle = load_bundle(preset_id)

    %{
      preset: bundle.preset,
      dark: to_client_map(bundle.dark),
      light: to_client_map(bundle.light),
      sources: bundle.sources
    }
  end

  @spec load_for_scheme(scheme(), String.t()) :: %__MODULE__{}
  def load_for_scheme(scheme, preset_id \\ @default_preset_id)
      when scheme in [:dark, :light] do
    preset_id = normalize_preset_id(preset_id)

    case preset_id do
      "system" ->
        base = builtin_preset(scheme, "catppuccin")

        case read_conf_for_scheme(scheme) do
          {:ok, conf} -> merge_conf(base, conf)
          :missing -> base
        end

      id ->
        builtin_preset(scheme, id)
    end
  end

  @spec builtin_preset(scheme(), String.t()) :: %__MODULE__{}
  def builtin_preset(scheme, preset_id) when scheme in [:dark, :light] do
    case Builtins.variant_key(preset_id, scheme) do
      nil ->
        builtin_preset(scheme, @default_preset_id)

      key ->
        key
        |> Builtins.fetch_variant()
        |> build_variant()
    end
  end

  @doc false
  @spec build_variant(map()) :: %__MODULE__{}
  def build_variant(spec) when is_map(spec) do
    palette =
      case Map.get(spec, :lut, :tinted) do
        :baseline ->
          build_xterm256_palette()

        :tinted ->
          grays = Map.get(spec, :grays) || Builtins.pad_grays([spec.bg, spec.fg])
          build_catppuccin256(spec.ansi16, grays, hex_to_rgb(spec.cube_tint))
      end

    %__MODULE__{
      id: spec.id,
      background: hex_to_rgb(spec.bg),
      foreground: hex_to_rgb(spec.fg),
      cursor: hex_to_rgb(spec.cursor),
      chrome: chrome_tokens(spec),
      palette: palette
    }
  end

  @spec active(%__MODULE__{}, scheme()) :: %__MODULE__{}
  def active(theme, _scheme) when is_struct(theme, __MODULE__), do: theme

  @spec active(map(), scheme()) :: %__MODULE__{}
  def active(%{dark: dark, light: light}, scheme) when scheme in [:dark, :light] do
    if scheme == :dark, do: dark, else: light
  end

  @spec to_client_map(%__MODULE__{}) :: map()
  def to_client_map(%__MODULE__{} = theme) do
    %{
      id: theme.id,
      chrome: theme.chrome,
      palette: Enum.map(theme.palette, fn {r, g, b} -> [r, g, b] end)
    }
  end

  @doc """
  Rewrites libghostty OSC color query responses so shell programs see the
  active DevIDE theme instead of the renderer baseline palette.
  """
  @spec rewrite_pty_write(binary(), %__MODULE__{}) :: binary()
  def rewrite_pty_write(data, %__MODULE__{} = theme) when is_binary(data) do
    if :binary.match(data, "\e]") == :nomatch do
      data
    else
      data
      |> rewrite_osc_colors(theme)
      |> rewrite_osc_palette(theme)
    end
  end

  @doc false
  @spec parse_conf(binary()) :: map()
  def parse_conf(content) when is_binary(content) do
    content
    |> String.split(~r/\R/, trim: true)
    |> Enum.reduce(%{palette: %{}}, &parse_conf_line/2)
  end

  defp normalize_preset_id(id) when id in @preset_ids, do: id
  defp normalize_preset_id(_), do: @default_preset_id

  defp chrome_tokens(spec) do
    %{
      "--devide-term-bg" => spec.bg,
      "--devide-term-fg" => spec.fg,
      "--devide-term-border" => spec.border,
      "--devide-term-selection" => spec.selection,
      "--devide-term-cursor" => spec.cursor,
      "--devide-term-prompt" => spec.prompt,
      "--devide-term-muted" => spec.muted,
      "--devide-term-success" => spec.success,
      "--devide-term-warning" => spec.warning,
      "--devide-term-error" => spec.error,
      "--devide-term-info" => spec.info,
      "--devide-term-scrollbar-track" => spec.scrollbar_track,
      "--devide-term-scrollbar-thumb" => spec.scrollbar_thumb,
      "--devide-term-scrollbar-active" => spec.scrollbar_active,
      "--devide-term-focus-ring" => spec.focus,
      "--devide-term-prompt-border" => spec.prompt_border
    }
  end

  defp merge_conf(%__MODULE__{} = preset, conf) when is_map(conf) do
    palette =
      preset.palette
      |> List.to_tuple()
      |> then(fn tuple ->
        conf_palette = Map.get(conf, :palette, %{})

        Enum.reduce(0..255, tuple, fn index, acc ->
          case Map.get(conf_palette, index) do
            nil -> acc
            rgb -> put_elem(acc, index, rgb)
          end
        end)
        |> Tuple.to_list()
      end)

    chrome =
      preset.chrome
      |> maybe_put_chrome("--devide-term-bg", conf[:background_hex])
      |> maybe_put_chrome("--devide-term-fg", conf[:foreground_hex])
      |> maybe_put_chrome("--devide-term-cursor", conf[:cursor_color])
      |> maybe_put_chrome("--devide-term-selection", conf[:selection_background])

    cursor =
      case conf[:cursor_color] do
        "#" <> _ = hex -> hex_to_rgb(hex)
        _ -> preset.cursor
      end

    %{
      preset
      | id: "custom",
        background: conf[:background] || preset.background,
        foreground: conf[:foreground] || preset.foreground,
        cursor: cursor,
        chrome: chrome,
        palette: palette
    }
  end

  defp maybe_put_chrome(chrome, _key, nil), do: chrome
  defp maybe_put_chrome(chrome, key, hex) when is_binary(hex), do: Map.put(chrome, key, hex)

  defp parse_conf_line(line, acc) do
    line = String.trim(line)

    cond do
      line == "" or String.starts_with?(line, "#") ->
        acc

      match = Regex.run(~r/^palette\s*=\s*(\d{1,3})\s*=#?(.+)$/i, line) ->
        [_, index_s, color_s] = match
        index = String.to_integer(index_s)

        color_s = String.trim(color_s)
        color_s = if String.starts_with?(color_s, "#"), do: color_s, else: "#" <> color_s

        case parse_color(color_s) do
          {:ok, rgb} -> put_in(acc[:palette][index], rgb)
          :error -> acc
        end

      match = Regex.run(~r/^([a-z0-9_-]+)\s*=\s*(.+)$/i, line) ->
        [_, key, value] = match
        value = String.trim(value)
        key = String.downcase(key)

        case key do
          "background" ->
            with {:ok, rgb} <- parse_color(value),
                 hex <- rgb_to_hex(rgb) do
              acc
              |> Map.put(:background, rgb)
              |> Map.put(:background_hex, hex)
            else
              _ -> acc
            end

          "foreground" ->
            with {:ok, rgb} <- parse_color(value),
                 hex <- rgb_to_hex(rgb) do
              acc
              |> Map.put(:foreground, rgb)
              |> Map.put(:foreground_hex, hex)
            else
              _ -> acc
            end

          "cursor-color" ->
            with {:ok, rgb} <- parse_color(value),
                 hex <- rgb_to_hex(rgb) do
              Map.put(acc, :cursor_color, hex)
            else
              _ -> acc
            end

          "selection-background" ->
            Map.put(acc, :selection_background, value)

          _ ->
            acc
        end

      true ->
        acc
    end
  end

  # Paths are operator-configured theme files under the user home (omarchy / ghostty).
  # sobelow_skip ["Traversal.FileModule"]
  defp read_conf_for_scheme(scheme) do
    case first_existing_path(scheme) do
      nil -> :missing
      path -> {:ok, parse_conf(File.read!(path))}
    end
  rescue
    _ -> :missing
  end

  defp first_existing_path(scheme) do
    scheme
    |> paths_for_scheme()
    |> Enum.map(&expand_path/1)
    |> Enum.find(&File.regular?/1)
  end

  defp paths_for_scheme(scheme) do
    defaults =
      case scheme do
        :dark ->
          [
            "~/.config/omarchy/current/theme/ghostty.conf",
            "~/.config/ghostty/config"
          ]

        :light ->
          [
            "~/.config/omarchy/current/theme/ghostty-light.conf",
            "~/.config/omarchy/current/theme/ghostty.conf"
          ]
      end

    config =
      Application.get_env(:dev_ide, :terminal_theme_paths, %{})
      |> Map.get(scheme, defaults)

    (List.wrap(config) ++ defaults)
    |> Enum.uniq()
  end

  defp expand_path(path) when is_binary(path) do
    path
    |> String.replace_prefix("~", System.get_env("HOME") || "")
    |> Path.expand()
  end

  defp rewrite_osc_colors(data, theme) do
    Regex.replace(@osc_color, data, fn _whole, ps, terminator ->
      value =
        case ps do
          "10" -> rgb_to_x11(theme.foreground)
          "11" -> rgb_to_x11(theme.background)
          "12" -> rgb_to_x11(theme.cursor)
        end

      "\e]" <> ps <> ";" <> value <> terminator
    end)
  end

  defp rewrite_osc_palette(data, theme) do
    Regex.replace(@osc_palette, data, fn _whole, index_s, terminator ->
      index = String.to_integer(index_s)
      rgb = Enum.at(theme.palette, index) || {0, 0, 0}
      "\e]4;" <> index_s <> ";" <> rgb_to_x11(rgb) <> terminator
    end)
  end

  defp build_catppuccin256(ansi16, gray_ramp, cube_tint) do
    baseline = build_xterm256_palette()

    palette =
      Enum.map(0..255, fn index ->
        cond do
          index < 16 ->
            hex_to_rgb(Enum.at(ansi16, index))

          index < 232 ->
            blend_rgb(Enum.at(baseline, index), cube_tint, 0.42)

          true ->
            gray_index = index - 232
            hex = Enum.at(gray_ramp, min(gray_index, length(gray_ramp) - 1))
            hex_to_rgb(hex)
        end
      end)

    palette
  end

  defp build_xterm256_palette do
    vga = [
      {0, 0, 0},
      {128, 0, 0},
      {0, 128, 0},
      {128, 128, 0},
      {0, 0, 128},
      {128, 0, 128},
      {0, 128, 128},
      {192, 192, 192},
      {128, 128, 128},
      {255, 0, 0},
      {0, 255, 0},
      {255, 255, 0},
      {0, 0, 255},
      {255, 0, 255},
      {0, 255, 255},
      {255, 255, 255}
    ]

    cube =
      for i <- 0..215 do
        r = div(i, 36)
        g = div(rem(i, 36), 6)
        b = rem(i, 6)
        conv = fn c -> if c == 0, do: 0, else: 55 + c * 40 end
        {conv.(r), conv.(g), conv.(b)}
      end

    grays = for i <- 0..23, do: {8 + i * 10, 8 + i * 10, 8 + i * 10}

    Enum.map(0..255, fn
      i when i < 16 -> Enum.at(vga, i)
      i when i < 232 -> Enum.at(cube, i - 16)
      i -> Enum.at(grays, i - 232)
    end)
  end

  defp blend_rgb({ar, ag, ab}, {br, bg, bb}, t) do
    f = 1 - t
    {round(ar * f + br * t), round(ag * f + bg * t), round(ab * f + bb * t)}
  end

  defp parse_color("#" <> hex) when byte_size(hex) in [6, 8], do: {:ok, hex_to_rgb("#" <> hex)}
  defp parse_color("rgb:" <> rest), do: parse_rgb_colon(rest)
  defp parse_color(value), do: parse_color("#" <> value)

  defp parse_rgb_colon(rest) do
    case String.split(rest, "/") do
      [rs, gs, bs] ->
        with {r, ""} <- Integer.parse(rs, 16),
             {g, ""} <- Integer.parse(gs, 16),
             {b, ""} <- Integer.parse(bs, 16) do
          scale = if String.length(rs) == 4, do: 16, else: 1
          {:ok, {div(r, scale), div(g, scale), div(b, scale)}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp hex_to_rgb("#" <> hex) when byte_size(hex) >= 6 do
    <<r::binary-size(2), g::binary-size(2), b::binary-size(2), _::binary>> = hex
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
  end

  defp rgb_to_hex({r, g, b}) do
    "#" <>
      (r |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase()) <>
      (g |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase()) <>
      (b |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase())
  end

  # XTerm-canonical color reply (`rgb:rrrr/gggg/bbbb`, 16-bit channels). Query
  # replies use this form rather than `#rrggbb` because it is what XTerm itself
  # answers with, so strict clients parse it unambiguously. 8-bit channels are
  # expanded by hex doubling (0x1e -> "1e1e").
  defp rgb_to_x11({r, g, b}) do
    "rgb:" <> doubled_hex(r) <> "/" <> doubled_hex(g) <> "/" <> doubled_hex(b)
  end

  defp doubled_hex(channel) do
    hex = channel |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase()
    hex <> hex
  end
end
