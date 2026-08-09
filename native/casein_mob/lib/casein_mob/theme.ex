defmodule CaseinMob.Theme do
  @moduledoc """
  Casein's brand theme for the mobile companion.

  The palette is the web cockpit's (`assets/css/app.css`) converted from OKLCH
  to sRGB, so a workspace looks like the same product on the phone as in the
  browser: indigo primary on blue-tinted near-black surfaces.

  Applied at boot by `use Mob.App, theme: CaseinMob.Theme` in `CaseinMob.App`.
  `light/0` is the daylight counterpart — same hues, inverted surfaces — used by
  the theme switcher on the demo home screen.

  ## Why this is not `mob_themes`

  Hex package `mob_themes` is Mob's stock showcase pack (Obsidian violet,
  Citrus, Birch, …). It is **not** Casein's design system. It used to be
  declared as `config :mob, :default_style, :mob_themes`, which made
  `Mob.Plugins.boot/1` clobber the brand theme after `use Mob.App, theme:` and
  boot devices into Obsidian violet. That dep is deliberately absent from
  `mix.exs` / `mob.exs`; product screens render through this module only.

  Semantic *status* colours (running / needs action / failed / done) are not
  theme tokens here. Prefer the web cockpit's severity tokens when those land
  (#729 / PR #771); do not invent a parallel severity palette in this module.
  """

  @doc "The default (dark) theme."
  @spec theme() :: Mob.Theme.t()
  def theme, do: dark()

  @doc "Dark: near-black blue-tinted surfaces, indigo primary."
  @spec dark() :: Mob.Theme.t()
  def dark do
    Mob.Theme.build(
      # ── Brand ────────────────────────────────────────────────────────────
      # #605DFF — web --color-primary oklch(58% .233 277)
      primary: 0xFF605DFF,
      on_primary: 0xFFF3F4FF,
      # #8C4FFF — web --color-accent
      secondary: 0xFF8C4FFF,
      on_secondary: 0xFFF6F1FF,

      # ── Surfaces ─────────────────────────────────────────────────────────
      # #13171C — deepest (web base-300)
      background: 0xFF13171C,
      on_background: 0xFFE6EDF5,
      # #1A1F26 — card
      surface: 0xFF1A1F26,
      # #262D36 — card-on-card, chips, secondary buttons
      surface_raised: 0xFF262D36,
      on_surface: 0xFFE6EDF5,
      # #8A94A2 — secondary text
      muted: 0xFF8A94A2,

      # ── Utility ──────────────────────────────────────────────────────────
      # brighter than the web #EA003E so it reads on a dark surface
      error: 0xFFFF5470,
      on_error: 0xFF1A0209,
      # #2C333D — hairline outlines
      border: 0xFF2C333D,
      radius_sm: 8,
      radius_md: 12,
      radius_lg: 18,
      radius_pill: 999
    )
  end

  @doc "Light: same hues, inverted surfaces."
  @spec light() :: Mob.Theme.t()
  def light do
    Mob.Theme.build(
      primary: 0xFF4F46E5,
      on_primary: 0xFFFFFFFF,
      secondary: 0xFF7C3AED,
      on_secondary: 0xFFFFFFFF,
      background: 0xFFF5F7FA,
      on_background: 0xFF11161C,
      surface: 0xFFFFFFFF,
      surface_raised: 0xFFEDF1F6,
      on_surface: 0xFF11161C,
      muted: 0xFF5B6673,
      error: 0xFFD11341,
      on_error: 0xFFFFFFFF,
      border: 0xFFDCE2EA,
      radius_sm: 8,
      radius_md: 12,
      radius_lg: 18,
      radius_pill: 999
    )
  end
end
