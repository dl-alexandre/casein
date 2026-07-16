defmodule DevIdeWeb.WorkspaceLive.Show.GrokPermissionPanel do
  @moduledoc false

  use DevIdeWeb, :html

  attr :requests, :list, required: true

  def grok_permission_panel(assigns) do
    ~H"""
    <aside
      :if={@requests != []}
      id="grok-permission-center"
      aria-label="Grok permission requests"
      aria-live="assertive"
      class="fixed inset-x-2 bottom-2 z-50 overflow-hidden rounded-2xl border border-amber-400/35 bg-base-100/95 shadow-2xl shadow-black/20 backdrop-blur-xl sm:inset-x-auto sm:right-5 sm:bottom-5 sm:w-[min(28rem,calc(100vw-2.5rem))]"
    >
      <header class="flex items-start gap-3 border-b border-base-300/80 bg-amber-400/8 px-4 py-3">
        <div class="relative mt-0.5 flex size-9 shrink-0 items-center justify-center rounded-xl border border-amber-400/30 bg-amber-400/12 text-amber-700 dark:text-amber-300">
          <.icon name="hero-shield-exclamation" class="size-5" />
          <span
            class="absolute -right-0.5 -top-0.5 size-2.5 rounded-full border-2 border-base-100 bg-amber-400 motion-safe:animate-pulse"
            aria-hidden="true"
          ></span>
        </div>
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <h2 class="text-sm font-semibold tracking-tight text-base-content">Agent approval</h2>
            <span class="rounded-full border border-amber-400/30 bg-amber-400/10 px-1.5 py-0.5 text-[10px] font-semibold tabular-nums text-amber-700 dark:text-amber-300">
              {length(@requests)} pending
            </span>
          </div>
          <p class="mt-0.5 text-xs leading-5 text-base-content/60">
            Grok is paused until an operator responds. First response wins.
          </p>
        </div>
      </header>

      <div class="max-h-[min(28rem,65dvh)] divide-y divide-base-300/70 overflow-y-auto overscroll-contain">
        <article
          :for={request <- @requests}
          id={"grok-permission-" <> request.dom_id}
          class="px-4 py-3.5"
        >
          <div class="flex min-w-0 items-center gap-2 text-[10px] font-semibold uppercase tracking-[0.14em] text-base-content/45">
            <span class="inline-flex items-center gap-1.5">
              <span class="size-1.5 rounded-full bg-amber-400" aria-hidden="true"></span> Grok
            </span>
            <span aria-hidden="true">/</span>
            <span class="truncate normal-case tracking-normal" title={request.session_id}>
              {request.session_label}
            </span>
          </div>

          <h3 class="mt-2 text-sm font-medium leading-5 text-base-content">
            {request.title}
          </h3>

          <div class="mt-3 flex flex-wrap items-center gap-2">
            <button
              :for={option <- request.options}
              type="button"
              phx-click="grok_permission:respond"
              phx-value-attachment-key={request.attachment_key}
              phx-value-request-id={request.request_id}
              phx-value-option-id={option.option_id}
              phx-disable-with="Sending…"
              class={option_button_class(option.kind)}
            >
              <.icon name={option_icon(option.kind)} class="size-3.5" />
              <span>{option.name}</span>
            </button>

            <button
              :if={not deny_option_offered?(request.options)}
              type="button"
              phx-click="grok_permission:cancel"
              phx-value-attachment-key={request.attachment_key}
              phx-value-request-id={request.request_id}
              phx-disable-with="Denying…"
              class="inline-flex min-h-9 items-center justify-center gap-1.5 rounded-lg border border-error/30 bg-error/5 px-3 text-xs font-semibold text-error transition duration-150 hover:border-error/50 hover:bg-error/10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-error/35"
            >
              <.icon name="hero-x-mark" class="size-3.5" /> Deny request
            </button>
          </div>
        </article>
      </div>
    </aside>
    """
  end

  defp option_button_class(kind) do
    cond do
      reject_kind?(kind) ->
        "inline-flex min-h-9 items-center justify-center gap-1.5 rounded-lg border border-error/30 bg-error/5 px-3 text-xs font-semibold text-error transition duration-150 hover:border-error/50 hover:bg-error/10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-error/35"

      persistent_kind?(kind) ->
        "inline-flex min-h-9 items-center justify-center gap-1.5 rounded-lg border border-amber-500/30 bg-amber-500/8 px-3 text-xs font-semibold text-amber-700 transition duration-150 hover:border-amber-500/50 hover:bg-amber-500/15 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500/35 dark:text-amber-300"

      true ->
        "inline-flex min-h-9 items-center justify-center gap-1.5 rounded-lg border border-success/30 bg-success/8 px-3 text-xs font-semibold text-success transition duration-150 hover:border-success/50 hover:bg-success/15 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-success/35"
    end
  end

  defp option_icon(kind) do
    cond do
      reject_kind?(kind) -> "hero-x-mark"
      persistent_kind?(kind) -> "hero-lock-open"
      true -> "hero-check"
    end
  end

  defp deny_option_offered?(options), do: Enum.any?(options, &reject_kind?(&1.kind))

  defp reject_kind?(kind) when is_binary(kind) do
    String.starts_with?(kind, "reject") or String.starts_with?(kind, "deny")
  end

  defp reject_kind?(_kind), do: false

  defp persistent_kind?(kind) when is_binary(kind) do
    String.contains?(kind, "always") or kind == "persistent"
  end

  defp persistent_kind?(_kind), do: false
end
