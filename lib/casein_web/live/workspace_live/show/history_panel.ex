defmodule CaseinWeb.WorkspaceLive.Show.HistoryPanel do
  @moduledoc """
  History (previous sessions) side panel for the workspace cockpit: a debounced
  bounded search over prior session context (session directory, audit, MCP
  activity, pane labels, preview history).

  Rendering carried over from the removed `/workspaces/:id/previous-sessions`
  page, restyled to the cockpit's side-panel conventions. State and events
  live in `CaseinWeb.WorkspaceLive.Show.HistoryEvents`.
  """

  use CaseinWeb, :html

  import CaseinWeb.WorkspaceLive.Show.UI, only: [panel_state: 1]

  alias CaseinWeb.WorkspaceLive.Show.StructuredAgentActivity

  @limit_options [
    {"10", "10"},
    {"20", "20"},
    {"50", "50"}
  ]

  @source_options [
    {"All", ""},
    {"Sessions", "session"},
    {"Audit", "audit"},
    {"Activity", "activity"},
    {"Labels", "label"},
    {"Preview", "preview"}
  ]

  attr :workspace_id, :string, required: true
  attr :history_form, :any, required: true
  attr :history_results, :list, required: true
  attr :history_payload, :map, required: true
  attr :history_error, :string, default: nil
  attr :history_loaded?, :boolean, required: true
  attr :agent_activity_loaded?, :boolean, default: false
  attr :agent_threads, :list, default: []
  attr :selected_agent_thread_id, :string, default: nil
  attr :agent_timeline, :list, default: []
  attr :agent_live_chunks, :list, default: []
  attr :agent_activity_error, :string, default: nil

  def history_panel(assigns) do
    assigns =
      assigns
      |> assign(:limit_options, @limit_options)
      |> assign(:source_options, @source_options)

    ~H"""
    <section
      id="history-panel"
      class="flex h-full min-h-0 flex-col border border-base-300 bg-base-100"
    >
      <div class="flex shrink-0 items-center justify-between gap-3 border-b border-base-300 bg-base-200/45 px-3 py-2">
        <div class="min-w-0">
          <h2 class="truncate text-sm font-semibold text-base-content">History</h2>
          <p id="history-count" class="text-xs text-base-content/55">
            <%= if @history_loaded? do %>
              {result_count_label(@history_results)} · limit {@history_payload.limit}
            <% else %>
              Previous session context
            <% end %>
          </p>
        </div>
        <button
          id="history-refresh-button"
          type="button"
          phx-click="history:refresh"
          class="inline-flex size-8 shrink-0 items-center justify-center rounded border border-base-300 bg-base-100 text-base-content/70 transition hover:border-primary/40 hover:bg-base-200 hover:text-base-content"
          title="Refresh history"
          aria-label="Refresh history"
        >
          <.icon name="hero-arrow-path" class="size-4" />
        </button>
      </div>

      <div class="min-h-0 flex-1 overflow-auto p-3">
        <.panel_state
          :if={@history_error}
          id="history-error"
          kind={:error}
          title="Could not load history"
          message={@history_error}
          action_label="Retry"
          action_event="history:refresh"
          class="mb-3"
        />
        <StructuredAgentActivity.structured_agent_activity
          loaded?={@agent_activity_loaded?}
          threads={@agent_threads}
          selected_thread_id={@selected_agent_thread_id}
          timeline={@agent_timeline}
          live_chunks={@agent_live_chunks}
          error={@agent_activity_error}
        />

        <.form
          id="history-search"
          for={@history_form}
          phx-change="history:search"
          phx-submit="history:search"
          class="rounded border border-base-300 bg-base-100 p-3 shadow-sm"
        >
          <div class="grid gap-2 sm:grid-cols-2 xl:grid-cols-4">
            <div class="sm:col-span-2 xl:col-span-4">
              <.input
                field={@history_form[:query]}
                type="search"
                label="Prompt text"
                placeholder="Search prompts, commands, titles"
                phx-debounce="350"
                class="mt-1 block w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-sm text-zinc-950 shadow-sm transition focus:border-zinc-500 focus:outline-none focus:ring-2 focus:ring-zinc-200"
              />
            </div>
            <.input
              field={@history_form[:workspace]}
              type="text"
              label="Workspace"
              placeholder={@workspace_id}
              phx-debounce="350"
              class="mt-1 block w-full rounded border border-zinc-300 bg-white px-2 py-1.5 font-mono text-sm text-zinc-950 shadow-sm transition focus:border-zinc-500 focus:outline-none focus:ring-2 focus:ring-zinc-200"
            />
            <.input
              field={@history_form[:source]}
              type="select"
              label="Source"
              options={@source_options}
              class="mt-1 block w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-sm text-zinc-950 shadow-sm transition focus:border-zinc-500 focus:outline-none focus:ring-2 focus:ring-zinc-200"
            />
            <.input
              field={@history_form[:session]}
              type="text"
              label="Session"
              placeholder="api-session"
              phx-debounce="350"
              class="mt-1 block w-full rounded border border-zinc-300 bg-white px-2 py-1.5 font-mono text-sm text-zinc-950 shadow-sm transition focus:border-zinc-500 focus:outline-none focus:ring-2 focus:ring-zinc-200"
            />
            <.input
              field={@history_form[:pane]}
              type="text"
              label="Pane"
              placeholder="%3"
              phx-debounce="350"
              class="mt-1 block w-full rounded border border-zinc-300 bg-white px-2 py-1.5 font-mono text-sm text-zinc-950 shadow-sm transition focus:border-zinc-500 focus:outline-none focus:ring-2 focus:ring-zinc-200"
            />
            <.input
              field={@history_form[:since]}
              type="date"
              label="Since"
              phx-debounce="350"
              class="mt-1 block w-full rounded border border-zinc-300 bg-white px-2 py-1.5 font-mono text-sm text-zinc-950 shadow-sm transition focus:border-zinc-500 focus:outline-none focus:ring-2 focus:ring-zinc-200"
            />
            <.input
              field={@history_form[:until]}
              type="date"
              label="Until"
              phx-debounce="350"
              class="mt-1 block w-full rounded border border-zinc-300 bg-white px-2 py-1.5 font-mono text-sm text-zinc-950 shadow-sm transition focus:border-zinc-500 focus:outline-none focus:ring-2 focus:ring-zinc-200"
            />
            <.input
              field={@history_form[:limit]}
              type="select"
              label="Limit"
              options={@limit_options}
              class="mt-1 block w-full rounded border border-zinc-300 bg-white px-2 py-1.5 text-sm text-zinc-950 shadow-sm transition focus:border-zinc-500 focus:outline-none focus:ring-2 focus:ring-zinc-200"
            />
          </div>

          <div class="mt-2 flex justify-end">
            <button
              id="history-clear"
              type="button"
              phx-click="history:clear"
              class="inline-flex items-center gap-1 rounded border border-zinc-300 bg-white px-2.5 py-1.5 text-xs font-medium text-zinc-700 transition hover:bg-zinc-50"
            >
              <.icon name="hero-x-mark" class="size-3.5" /> Clear
            </button>
          </div>
        </.form>

        <section id="history-results" class="mt-3 space-y-3">
          <%= cond do %>
            <% not @history_loaded? -> %>
              <div
                id="history-loading"
                class="async-wait rounded border border-zinc-200 bg-zinc-50 px-4 py-6 text-sm text-zinc-500"
                role="status"
                aria-live="polite"
              >
                Loading previous sessions…
              </div>
            <% @history_error -> %>
              <div id="history-error-results-suppressed" class="hidden" aria-hidden="true"></div>
            <% @history_results == [] -> %>
              <.panel_state
                id="history-empty"
                kind={:empty}
                message="No matching session context."
              />
            <% true -> %>
              <ol class="space-y-3">
                <%= for result <- @history_results do %>
                  <li
                    id={"history-result-" <> dom_id(result)}
                    class="rounded border border-zinc-200 bg-white p-4 shadow-sm"
                  >
                    <div class="flex flex-wrap items-center gap-2">
                      <span class="rounded bg-zinc-100 px-2 py-density-body font-mono text-density-body text-zinc-700">
                        {source_label(result.source)}
                      </span>
                      <%= if status = result_status(result) do %>
                        <span class={status_badge_class(status)}>
                          {status}
                        </span>
                      <% end %>
                      <%= if result.occurred_at do %>
                        <time class="font-mono text-density-body text-zinc-500">
                          {format_time(result.occurred_at)}
                        </time>
                      <% end %>
                      <%= if href = result_href(result) do %>
                        <.link
                          navigate={href}
                          class="ml-auto inline-flex items-center gap-1 rounded border border-zinc-200 px-2 py-density-body text-density-body font-medium text-zinc-700 transition hover:bg-zinc-50"
                        >
                          <.icon name="hero-arrow-top-right-on-square" class="size-3" /> Open
                        </.link>
                      <% end %>
                    </div>

                    <h3 class="mt-2 text-sm font-semibold text-zinc-950">
                      {result.title}
                    </h3>
                    <p class="mt-1 text-sm leading-6 text-zinc-600">
                      {result.summary}
                    </p>

                    <dl class="mt-3 grid gap-2 text-xs sm:grid-cols-3">
                      <div>
                        <dt class="text-zinc-400">Session</dt>
                        <dd class="truncate font-mono text-zinc-700">{result.session || "—"}</dd>
                      </div>
                      <div>
                        <dt class="text-zinc-400">Pane</dt>
                        <dd class="font-mono text-zinc-700">{result.pane || "—"}</dd>
                      </div>
                      <div>
                        <dt class="text-zinc-400">Matched</dt>
                        <dd class="truncate font-mono text-zinc-700">
                          {matched_fields_label(result.matched_fields)}
                        </dd>
                      </div>
                      <%= if preview = preview_label(result) do %>
                        <div class="sm:col-span-3">
                          <dt class="text-zinc-400">Preview</dt>
                          <dd class="truncate font-mono text-zinc-700">{preview}</dd>
                        </div>
                      <% end %>
                    </dl>
                  </li>
                <% end %>
              </ol>
          <% end %>
        </section>
      </div>
    </section>
    """
  end

  defp result_count_label(results) do
    case length(results) do
      1 -> "1 result"
      count -> "#{count} results"
    end
  end

  defp source_label(source) when is_atom(source), do: source |> Atom.to_string() |> humanize()
  defp source_label(source) when is_binary(source), do: humanize(source)
  defp source_label(_), do: "Context"

  defp result_status(%{status: status}) when status not in [nil, ""] do
    status_string(status)
  end

  defp result_status(%{metadata: metadata}) when is_map(metadata) do
    metadata |> metadata_value(:status) |> status_string()
  end

  defp result_status(_result), do: nil

  defp metadata_value(metadata, key) when is_atom(key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp status_string(value) when is_atom(value), do: value |> Atom.to_string() |> humanize()
  defp status_string(value) when is_binary(value) and value != "", do: humanize(value)
  defp status_string(_value), do: nil

  defp status_badge_class("Attention"),
    do:
      "rounded border border-status-warning-border bg-status-warning-soft px-2 py-density-body text-density-body font-medium text-status-warning-fg"

  defp status_badge_class("Error"),
    do:
      "rounded border border-status-danger-border bg-status-danger-soft px-2 py-density-body text-density-body font-medium text-status-danger-fg"

  defp status_badge_class("Done"),
    do:
      "rounded border border-status-ok-border bg-status-ok-soft px-2 py-density-body text-density-body font-medium text-status-ok-fg"

  defp status_badge_class(_status),
    do:
      "rounded border border-zinc-200 bg-zinc-50 px-2 py-density-body text-density-body font-medium text-zinc-700"

  defp humanize(value) do
    value
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp format_time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  defp format_time(%NaiveDateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  defp format_time(value) when is_binary(value), do: value
  defp format_time(_), do: ""

  defp matched_fields_label(fields) when is_list(fields) and fields != [] do
    fields
    |> Enum.take(4)
    |> Enum.join(", ")
  end

  defp matched_fields_label(_), do: "—"

  defp preview_label(%{preview: preview}) when is_map(preview) do
    [
      preview_action_ref(preview),
      preview_agent_ref(preview),
      metadata_value(preview, :title),
      preview_primary_ref(preview),
      preview_recording_ref(preview),
      preview_artifact_ref(preview)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
    |> blank_to_nil()
  end

  defp preview_label(%{"preview" => preview}) when is_map(preview) do
    preview_label(%{preview: preview})
  end

  defp preview_label(_result), do: nil

  defp result_href(%{href: href}) when is_binary(href) and href != "", do: href
  defp result_href(%{"href" => href}) when is_binary(href) and href != "", do: href
  defp result_href(_result), do: nil

  defp preview_primary_ref(preview) do
    metadata_value(preview, :display_url) ||
      metadata_value(preview, :url) ||
      preview_port_path(preview) ||
      metadata_value(preview, :path) ||
      metadata_value(preview, :session_id)
  end

  defp preview_action_ref(preview) do
    metadata_value(preview, :agent_action) || metadata_value(preview, :tool)
  end

  defp preview_agent_ref(preview) do
    [metadata_value(preview, :agent_session), metadata_value(preview, :agent_pane)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> blank_to_nil()
  end

  defp preview_artifact_ref(preview) do
    metadata_value(preview, :screenshot_url) || metadata_value(preview, :artifact_url)
  end

  defp preview_recording_ref(preview) do
    metadata_value(preview, :recording_url) ||
      metadata_value(preview, :recording_path) ||
      metadata_value(preview, :recording_id)
  end

  defp preview_port_path(preview) do
    case {metadata_value(preview, :port), metadata_value(preview, :path)} do
      {nil, _path} -> nil
      {port, nil} -> ":#{port}"
      {port, path} -> ":#{port}#{path}"
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp dom_id(%{id: id}) when is_binary(id) do
    String.replace(id, ~r/[^a-zA-Z0-9_-]/, "-")
  end

  defp dom_id(_), do: Ecto.UUID.generate()
end
