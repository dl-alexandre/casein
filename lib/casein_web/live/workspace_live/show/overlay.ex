defmodule CaseinWeb.WorkspaceLive.Show.Overlay do
  @moduledoc """
  Single arbiter for the cockpit's floating surfaces.

  The cockpit renders several surfaces that float above the workspace — the
  command palette, the context menu, the audit drawer, the notifications
  drawer, the clipboard drawer, the session-template library, and the template
  preview. Each one owned an independent open flag, so nothing prevented the
  palette, a drawer, and a modal being open simultaneously (stacked overlays,
  ambiguous `Escape`, two competing keyboard-focus owners).

  This module makes "at most one floating surface at a time" a property of the
  socket rather than a convention. Every genuine *open* transition calls
  `close_others/2` first; the caller then applies its own bespoke open logic
  (the palette computes its item list, the notifications drawer runs its first
  inbox load, ...), which is why this module deliberately does not own opening.

  Closing is left alone on purpose: toggling a drawer shut must not reach in
  and clear unrelated state.

  ## Not arbitrated

    * **The leader cheatsheet** is client-side only (`JS.toggle` on
      `#leader-cheatsheet` in `WorkspaceShell`), so there is no socket state to
      arbitrate. It is a transient help layer, not a focus owner.
    * **The sessions/windows sidebar** and **focus mode** (`chrome_visible`)
      are layout, not overlay — they dock beside the terminal rather than
      floating over it.
  """

  import Phoenix.Component, only: [assign: 3]

  @typedoc "A floating surface subject to the one-at-a-time rule."
  @type overlay ::
          :palette
          | :context_menu
          | :audit_drawer
          | :notifications
          | :clipboard_drawer
          | :template_library
          | :template_preview

  # Reset applied when a surface is closed. `:template_preview` is its own
  # surface rather than a child of `:template_library` — previewing a template
  # replaces the drawer (see `TmuxTemplateEvents."tmux:preview_template"`)
  # rather than stacking above it.
  @resets %{
    palette: [palette_open: false],
    context_menu: [context_menu: nil],
    audit_drawer: [audit_drawer_open: false],
    notifications: [notif_drawer_open: false],
    clipboard_drawer: [clipboard_drawer_open: false],
    template_library: [template_library_open: false],
    template_preview: [template_preview: nil]
  }

  @overlays Map.keys(@resets)

  @doc "Every floating surface subject to the one-at-a-time rule."
  @spec overlays() :: [overlay()]
  def overlays, do: @overlays

  @doc """
  Close every floating surface except `keep`.

  Call this at the top of an *open* transition. The caller stays responsible
  for actually opening `keep` — this only guarantees nothing else is left up.
  """
  @spec close_others(Phoenix.LiveView.Socket.t(), overlay()) :: Phoenix.LiveView.Socket.t()
  def close_others(socket, keep) when keep in @overlays do
    Enum.reduce(@overlays -- [keep], socket, &close(&2, &1))
  end

  @doc "Close every floating surface."
  @spec close_all(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close_all(socket), do: Enum.reduce(@overlays, socket, &close(&2, &1))

  @doc "Close a single floating surface."
  @spec close(Phoenix.LiveView.Socket.t(), overlay()) :: Phoenix.LiveView.Socket.t()
  def close(socket, overlay) when overlay in @overlays do
    Enum.reduce(@resets[overlay], socket, fn {key, value}, sock ->
      # Presence-guarded: the notifications drawer mounts from its own module
      # and is reusable outside this cockpit, so a socket may legitimately carry
      # only a subset of these assigns. Resetting a key the surface never had
      # would invent state rather than clear it.
      if Map.has_key?(sock.assigns, key), do: assign(sock, key, value), else: sock
    end)
  end
end
