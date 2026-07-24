defmodule CaseinWeb.WorkspaceLive.Show.ContextMenuEvents do
  # "ctx:*" handle_event clauses delegated from CaseinWeb.WorkspaceLive.Show.
  # The ContextMenu JS hook pushes ctx:open with a menu id, the trigger's
  # data-ctx-* payload, and viewport coordinates; the item list is rebuilt
  # server-side on every open (ContextMenu.items/3) so stale or fabricated
  # payloads can at most open a menu of no-op items — mutations stay gated in
  # their own handlers.
  @moduledoc false

  import Phoenix.Component

  alias CaseinWeb.WorkspaceLive.Show.ContextMenu

  def handle_event("ctx:open", %{"menu" => menu, "x" => x, "y" => y} = params, socket)
      when is_binary(menu) do
    ctx = sanitize_ctx(params["ctx"])

    # {:reply, ...} so the hook's pushEvent callback fires after the patch —
    # that's what re-clamps/re-focuses when the menu was already open.
    case ContextMenu.items(menu, ctx, socket.assigns) do
      [] ->
        {:reply, %{}, assign(socket, :context_menu, nil)}

      items ->
        {:reply, %{},
         assign(socket, :context_menu, %{
           menu: menu,
           ctx: ctx,
           x: clamp_coord(x),
           y: clamp_coord(y),
           items: items
         })}
    end
  end

  def handle_event("ctx:open", _params, socket), do: {:noreply, socket}

  def handle_event("ctx:close", _params, socket),
    do: {:noreply, assign(socket, :context_menu, nil)}

  defp sanitize_ctx(ctx) when is_map(ctx) do
    for {k, v} <- ctx, is_binary(k), is_binary(v), into: %{}, do: {k, v}
  end

  defp sanitize_ctx(_), do: %{}

  # Coordinates only position the fixed-position menu (the hook re-clamps to
  # the viewport after mount); reject anything non-numeric or absurd.
  defp clamp_coord(n) when is_number(n), do: n |> round() |> max(0) |> min(100_000)
  defp clamp_coord(_), do: 0
end
