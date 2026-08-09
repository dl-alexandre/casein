defmodule CaseinWeb.WorkspaceLive.Show.AgentApprovals do
  @moduledoc false

  use CaseinWeb, :html

  alias Casein.AgentSessions.Provider.PendingRequest

  attr :requests, :list, required: true

  def pending_approvals(assigns) do
    assigns = assign(assigns, :pending_count, length(assigns.requests))

    ~H"""
    <section
      :if={@pending_count > 0}
      id="agent-approval-center"
      class="space-y-2"
      aria-label="Pending agent approvals"
      aria-live="polite"
    >
      <div class="flex items-center justify-between gap-3">
        <h3 class="flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-status-warning-fg">
          <.icon name="hero-shield-exclamation" class="size-4" /> Agent approvals
        </h3>
        <span class="rounded-full bg-status-warning-soft px-2 py-density-label text-density-label font-semibold text-status-warning-fg">
          {@pending_count} pending
        </span>
      </div>

      <div class="space-y-2">
        <.pending_request :for={request <- @requests} request={request} />
      </div>
    </section>
    """
  end

  attr :request, PendingRequest, required: true

  defp pending_request(assigns) do
    assigns = assign(assigns, :option_list?, PendingRequest.option_list?(assigns.request))

    ~H"""
    <article
      id={request_dom_id(@request)}
      class="rounded-xl border border-status-warning-border bg-status-warning-soft/70 p-3 text-status-warning-fg shadow-sm"
    >
      <div class="flex min-w-0 flex-wrap items-center gap-2">
        <h4 class="text-sm font-medium leading-5">{@request.title}</h4>
        <span class="rounded bg-status-warning/60 px-1.5 py-density-badge text-density-badge font-semibold uppercase tracking-wide">
          {provider_label(@request.provider_id)}
        </span>
      </div>
      <p
        :if={@request.detail}
        class="mt-2 whitespace-pre-wrap text-density-body leading-4 text-status-warning-fg/75"
      >
        {@request.detail}
      </p>
      <p :if={@option_list?} class="mt-1 text-density-label text-status-warning-fg/60">
        Agent paused · first response wins.
      </p>

      <div :if={@option_list?} class="mt-3 flex flex-wrap items-center gap-2">
        <button
          :for={option <- @request.options}
          type="button"
          phx-click="agent_approval:respond"
          phx-value-provider-id={@request.provider_id}
          phx-value-request-id={@request.request_id}
          phx-value-decision-kind="choice"
          phx-value-option-id={option.id}
          phx-disable-with="Sending…"
          class={option_button_class(option.kind)}
        >
          <.icon name={option_icon(option.kind)} class="size-3.5" />
          <span>{option.label}</span>
        </button>
        <button
          :if={not Enum.any?(@request.options, &reject_kind?(&1.kind))}
          type="button"
          phx-click="agent_approval:respond"
          phx-value-provider-id={@request.provider_id}
          phx-value-request-id={@request.request_id}
          phx-value-decision-kind="cancel"
          phx-disable-with="Denying…"
          class="inline-flex min-h-9 items-center justify-center gap-1.5 rounded-lg border border-error/30 bg-base-100 px-3 text-xs font-semibold text-error transition hover:bg-error/10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-error/35"
        >
          <.icon name="hero-x-mark" class="size-3.5" /> Deny request
        </button>
      </div>

      <div :if={not @option_list?} class="mt-3 space-y-2">
        <div class="flex justify-end gap-2">
          <button
            type="button"
            phx-click="agent_approval:respond"
            phx-value-provider-id={@request.provider_id}
            phx-value-request-id={@request.request_id}
            phx-value-decision-kind="decline"
            class="rounded-lg border border-status-danger-border bg-white px-2.5 py-1.5 text-density-label font-semibold text-status-danger-fg transition hover:bg-status-danger-soft focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-status-danger/40"
          >
            Reject
          </button>
          <button
            type="button"
            phx-click="agent_approval:respond"
            phx-value-provider-id={@request.provider_id}
            phx-value-request-id={@request.request_id}
            phx-value-decision-kind="accept"
            class="rounded-lg bg-status-ok px-2.5 py-1.5 text-density-label font-semibold text-white transition hover:-translate-y-px hover:bg-status-ok hover:shadow-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-status-ok/40"
          >
            Approve once
          </button>
        </div>

        <details class="rounded-lg border border-status-warning-border/70 bg-white/60 px-2.5 py-2">
          <summary class="cursor-pointer text-density-label font-semibold text-status-warning-fg">
            Approve with a policy amendment
          </summary>
          <div class="mt-2 grid gap-3">
            <form phx-submit="agent_approval:respond" class="space-y-2">
              <input type="hidden" name="provider-id" value={@request.provider_id} />
              <input type="hidden" name="request-id" value={@request.request_id} />
              <input type="hidden" name="decision-kind" value="execpolicy_amendment" />
              <.input
                id={request_dom_id(@request) <> "-execpolicy"}
                name="execpolicy-amendment"
                value=""
                type="textarea"
                label="Exec policy prefixes (one per line)"
                rows="2"
                required
              />
              <button
                type="submit"
                class="rounded-lg border border-status-warning/30 px-2.5 py-1.5 text-density-label font-semibold text-status-warning-fg hover:bg-status-warning-soft"
              >
                Approve and amend exec policy
              </button>
            </form>

            <form phx-submit="agent_approval:respond" class="space-y-2">
              <input type="hidden" name="provider-id" value={@request.provider_id} />
              <input type="hidden" name="request-id" value={@request.request_id} />
              <input type="hidden" name="decision-kind" value="network_policy_amendment" />
              <.input
                id={request_dom_id(@request) <> "-network-policy"}
                name="network-policy-amendment"
                value=""
                type="textarea"
                label="Network policy amendment (JSON object)"
                rows="2"
                required
              />
              <button
                type="submit"
                class="rounded-lg border border-status-warning/30 px-2.5 py-1.5 text-density-label font-semibold text-status-warning-fg hover:bg-status-warning-soft"
              >
                Apply network policy amendment
              </button>
            </form>
          </div>
        </details>
      </div>
    </article>
    """
  end

  defp request_dom_id(request) do
    encoded =
      {request.provider_id, request.request_id}
      |> :erlang.term_to_binary()
      |> Base.url_encode64(padding: false)

    "agent-approval-" <> encoded
  end

  defp provider_label(provider_id), do: provider_id |> to_string() |> humanize()

  defp option_button_class(kind) do
    cond do
      reject_kind?(kind) ->
        "inline-flex min-h-9 items-center justify-center gap-1.5 rounded-lg border border-error/30 bg-base-100 px-3 text-xs font-semibold text-error transition hover:bg-error/10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-error/35"

      persistent_kind?(kind) ->
        "inline-flex min-h-9 items-center justify-center gap-1.5 rounded-lg border border-status-warning/30 bg-status-warning/10 px-3 text-xs font-semibold text-status-warning-fg transition hover:bg-status-warning/15 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-status-warning/35"

      true ->
        "inline-flex min-h-9 items-center justify-center gap-1.5 rounded-lg bg-status-ok px-3 text-xs font-semibold text-white transition hover:-translate-y-px hover:bg-status-ok focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-status-ok/35"
    end
  end

  defp option_icon(kind) do
    cond do
      reject_kind?(kind) -> "hero-x-mark"
      persistent_kind?(kind) -> "hero-lock-open"
      true -> "hero-check"
    end
  end

  defp reject_kind?(kind) when is_binary(kind),
    do: String.starts_with?(kind, "reject") or String.starts_with?(kind, "deny")

  defp reject_kind?(kind) when is_atom(kind), do: kind |> Atom.to_string() |> reject_kind?()
  defp reject_kind?(_kind), do: false

  defp persistent_kind?(kind) when is_binary(kind),
    do: String.contains?(kind, "always") or kind == "persistent"

  defp persistent_kind?(kind) when is_atom(kind),
    do: kind |> Atom.to_string() |> persistent_kind?()

  defp persistent_kind?(_kind), do: false

  defp humanize(value) when is_binary(value),
    do: value |> String.replace(["_", "."], " ") |> String.capitalize()
end
