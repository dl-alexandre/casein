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
        <h3 class="flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-amber-700">
          <.icon name="hero-shield-exclamation" class="size-4" /> Agent approvals
        </h3>
        <span class="rounded-full bg-amber-100 px-2 py-0.5 text-[10px] font-semibold text-amber-900">
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
      class="rounded-xl border border-amber-300 bg-amber-50/70 p-3 text-amber-950 shadow-sm"
    >
      <div class="flex min-w-0 flex-wrap items-center gap-2">
        <h4 class="text-sm font-medium leading-5">{@request.title}</h4>
        <span class="rounded bg-amber-200/60 px-1.5 py-0.5 text-[9px] font-semibold uppercase tracking-wide">
          {provider_label(@request.provider_id)}
        </span>
      </div>
      <p
        :if={@request.detail}
        class="mt-2 whitespace-pre-wrap text-[11px] leading-4 text-amber-950/75"
      >
        {@request.detail}
      </p>
      <p :if={@option_list?} class="mt-1 text-[10px] text-amber-900/60">
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
      </div>

      <div :if={not @option_list?} class="mt-3 space-y-2">
        <div class="flex justify-end gap-2">
          <button
            type="button"
            phx-click="agent_approval:respond"
            phx-value-provider-id={@request.provider_id}
            phx-value-request-id={@request.request_id}
            phx-value-decision-kind="decline"
            class="rounded-lg border border-red-300 bg-white px-2.5 py-1.5 text-[10px] font-semibold text-red-700 transition hover:bg-red-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-400/40"
          >
            Reject
          </button>
          <button
            type="button"
            phx-click="agent_approval:respond"
            phx-value-provider-id={@request.provider_id}
            phx-value-request-id={@request.request_id}
            phx-value-decision-kind="accept"
            class="rounded-lg bg-emerald-600 px-2.5 py-1.5 text-[10px] font-semibold text-white transition hover:-translate-y-px hover:bg-emerald-500 hover:shadow-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500/40"
          >
            Approve once
          </button>
        </div>

        <details class="rounded-lg border border-amber-300/70 bg-white/60 px-2.5 py-2">
          <summary class="cursor-pointer text-[10px] font-semibold text-amber-900">
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
                class="rounded-lg border border-amber-500/30 px-2.5 py-1.5 text-[10px] font-semibold text-amber-900 hover:bg-amber-100"
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
                class="rounded-lg border border-amber-500/30 px-2.5 py-1.5 text-[10px] font-semibold text-amber-900 hover:bg-amber-100"
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
        "inline-flex min-h-9 items-center justify-center gap-1.5 rounded-lg border border-amber-500/30 bg-amber-500/10 px-3 text-xs font-semibold text-amber-800 transition hover:bg-amber-500/15 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500/35"

      true ->
        "inline-flex min-h-9 items-center justify-center gap-1.5 rounded-lg bg-emerald-600 px-3 text-xs font-semibold text-white transition hover:-translate-y-px hover:bg-emerald-500 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500/35"
    end
  end

  defp option_icon(kind) do
    cond do
      reject_kind?(kind) -> "hero-x-mark"
      persistent_kind?(kind) -> "hero-lock-open"
      true -> "hero-check"
    end
  end

  attr :codex_approvals, :list, default: []
  attr :grok_requests, :list, default: []

  def agent_approvals(assigns) do
    codex_approvals = Enum.filter(assigns.codex_approvals, &(field(&1, :status) == "pending"))

    assigns =
      assigns
      |> assign(:codex_approvals, codex_approvals)
      |> assign(:pending_count, length(codex_approvals) + length(assigns.grok_requests))

    ~H"""
    <section
      :if={@pending_count > 0}
      id="agent-approval-center"
      class="space-y-2"
      aria-label="Pending agent approvals"
      aria-live="polite"
    >
      <div class="flex items-center justify-between gap-3">
        <h3 class="flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-amber-700">
          <.icon name="hero-shield-exclamation" class="size-4" /> Agent approvals
        </h3>
        <span class="rounded-full bg-amber-100 px-2 py-0.5 text-[10px] font-semibold text-amber-900">
          {@pending_count} pending
        </span>
      </div>

      <div class="space-y-2">
        <.codex_approval :for={approval <- @codex_approvals} approval={approval} />
        <.grok_approval :for={request <- @grok_requests} request={request} />
      </div>
    </section>
    """
  end

  attr :approval, :map, required: true

  defp codex_approval(assigns) do
    ~H"""
    <article
      id={"codex-approval-" <> field(@approval, :id, "unknown")}
      class="rounded-xl border border-amber-300 bg-amber-50/70 p-3 text-amber-950 shadow-sm"
    >
      <div class="flex items-start gap-2">
        <span class="flex size-7 shrink-0 items-center justify-center rounded-lg bg-amber-100 text-amber-700">
          <.icon name={codex_approval_icon(field(@approval, :kind))} class="size-4" />
        </span>
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-2">
            <p class="text-xs font-semibold">
              {codex_approval_title(field(@approval, :kind))}
            </p>
            <span class="rounded bg-amber-200/60 px-1.5 py-0.5 text-[9px] font-semibold uppercase tracking-wide">
              Codex
            </span>
          </div>
          <p class="mt-0.5 truncate font-mono text-[9px] text-amber-900/55">
            {short_id(field(@approval, :thread_id))} · {relative_time(
              field(
                @approval,
                :requested_at
              )
            )}
          </p>
        </div>
      </div>

      <p :if={codex_approval_reason(@approval)} class="mt-2 text-[11px] leading-4 text-amber-950/75">
        {codex_approval_reason(@approval)}
      </p>
      <pre
        :if={codex_approval_command(@approval)}
        class="mt-2 max-h-24 overflow-auto rounded-lg bg-zinc-950 px-2.5 py-2 font-mono text-[10px] leading-4 text-zinc-200"
      >{codex_approval_command(@approval)}</pre>

      <div class="mt-3 flex justify-end gap-2">
        <button
          type="button"
          phx-click="codex:resolve_approval"
          phx-value-approval-id={field(@approval, :id)}
          phx-value-decision="decline"
          class="rounded-lg border border-red-300 bg-white px-2.5 py-1.5 text-[10px] font-semibold text-red-700 transition hover:bg-red-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-400/40"
        >
          Reject
        </button>
        <button
          type="button"
          phx-click="codex:resolve_approval"
          phx-value-approval-id={field(@approval, :id)}
          phx-value-decision="accept"
          class="rounded-lg bg-emerald-600 px-2.5 py-1.5 text-[10px] font-semibold text-white transition hover:-translate-y-px hover:bg-emerald-500 hover:shadow-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500/40"
        >
          Approve once
        </button>
      </div>
    </article>
    """
  end

  attr :request, :map, required: true

  defp grok_approval(assigns) do
    ~H"""
    <article
      id={"grok-permission-" <> field(@request, :dom_id, "unknown")}
      class="rounded-xl border border-amber-300 bg-amber-50/70 p-3 text-amber-950 shadow-sm"
    >
      <div class="flex min-w-0 flex-wrap items-center gap-2 text-[10px] font-semibold uppercase tracking-wide text-amber-900/55">
        <span>Grok</span>
        <span aria-hidden="true">·</span>
        <span class="truncate normal-case tracking-normal" title={field(@request, :session_id)}>
          {field(@request, :session_label, "Grok session")}
        </span>
      </div>
      <h4 class="mt-2 text-sm font-medium leading-5">{field(@request, :title)}</h4>
      <p class="mt-1 text-[10px] text-amber-900/60">Agent paused · first response wins.</p>

      <div class="mt-3 flex flex-wrap items-center gap-2">
        <button
          :for={option <- field(@request, :options, [])}
          type="button"
          phx-click="grok_permission:respond"
          phx-value-attachment-key={field(@request, :attachment_key)}
          phx-value-request-id={field(@request, :request_id)}
          phx-value-option-id={field(option, :option_id)}
          phx-disable-with="Sending…"
          class={grok_option_button_class(field(option, :kind))}
        >
          <.icon name={grok_option_icon(field(option, :kind))} class="size-3.5" />
          <span>{field(option, :name, "Allow")}</span>
        </button>

        <button
          :if={not deny_option_offered?(field(@request, :options, []))}
          type="button"
          phx-click="grok_permission:cancel"
          phx-value-attachment-key={field(@request, :attachment_key)}
          phx-value-request-id={field(@request, :request_id)}
          phx-disable-with="Denying…"
          class="inline-flex min-h-9 items-center justify-center gap-1.5 rounded-lg border border-error/30 bg-base-100 px-3 text-xs font-semibold text-error transition hover:bg-error/10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-error/35"
        >
          <.icon name="hero-x-mark" class="size-3.5" /> Deny request
        </button>
      </div>
    </article>
    """
  end

  defp codex_approval_icon("command_execution"), do: "hero-command-line"
  defp codex_approval_icon("file_change"), do: "hero-document-text"
  defp codex_approval_icon(_kind), do: "hero-shield-check"

  defp codex_approval_title("command_execution"), do: "Command execution"
  defp codex_approval_title("file_change"), do: "File changes"
  defp codex_approval_title("permissions"), do: "Additional permissions"
  defp codex_approval_title(kind), do: humanize(kind)

  defp codex_approval_reason(approval), do: payload_field(approval, "reason")

  defp codex_approval_command(approval),
    do: payload_field(approval, "command") || payload_field(approval, "grant_root")

  defp payload_field(approval, key) do
    approval
    |> field(:payload, %{})
    |> field(key)
  end

  defp grok_option_button_class(kind) do
    cond do
      reject_kind?(kind) ->
        "inline-flex min-h-9 items-center justify-center gap-1.5 rounded-lg border border-error/30 bg-base-100 px-3 text-xs font-semibold text-error transition hover:bg-error/10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-error/35"

      persistent_kind?(kind) ->
        "inline-flex min-h-9 items-center justify-center gap-1.5 rounded-lg border border-amber-500/30 bg-amber-500/10 px-3 text-xs font-semibold text-amber-800 transition hover:bg-amber-500/15 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-500/35"

      true ->
        "inline-flex min-h-9 items-center justify-center gap-1.5 rounded-lg bg-emerald-600 px-3 text-xs font-semibold text-white transition hover:-translate-y-px hover:bg-emerald-500 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500/35"
    end
  end

  defp grok_option_icon(kind) do
    cond do
      reject_kind?(kind) -> "hero-x-mark"
      persistent_kind?(kind) -> "hero-lock-open"
      true -> "hero-check"
    end
  end

  defp deny_option_offered?(options), do: Enum.any?(options, &reject_kind?(field(&1, :kind)))

  defp reject_kind?(kind) when is_binary(kind),
    do: String.starts_with?(kind, "reject") or String.starts_with?(kind, "deny")

  defp reject_kind?(_kind), do: false

  defp persistent_kind?(kind) when is_binary(kind),
    do: String.contains?(kind, "always") or kind == "persistent"

  defp persistent_kind?(_kind), do: false

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp field(map, key, default) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> existing_atom_field(map, key, default)
    end
  end

  defp field(_map, _key, default), do: default

  defp existing_atom_field(map, key, default) do
    Map.get(map, String.to_existing_atom(key), default)
  rescue
    ArgumentError -> default
  end

  defp humanize(nil), do: "Approval"
  defp humanize(value) when is_atom(value), do: value |> Atom.to_string() |> humanize()

  defp humanize(value) when is_binary(value),
    do: value |> String.replace(["_", "."], " ") |> String.capitalize()

  defp short_id(nil), do: "—"
  defp short_id(value) when is_binary(value), do: String.slice(value, 0, 8)
  defp short_id(value), do: value |> to_string() |> short_id()

  defp relative_time(%DateTime{} = datetime) do
    seconds = max(DateTime.diff(DateTime.utc_now(), datetime, :second), 0)

    cond do
      seconds < 60 -> "now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp relative_time(_datetime), do: ""
end
