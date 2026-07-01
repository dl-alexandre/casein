defmodule DevIdeWeb.WorkspaceLive.PreviousSessions do
  @moduledoc """
  Debounced browser UI for bounded previous-session search.

  The workspace cockpit can embed this later, but this route is intentionally
  separate so search does not hydrate history into the main LiveView.
  """

  use DevIdeWeb, :live_view

  alias DevIDE.Agents.Activity
  alias DevIDE.Audit
  alias DevIDE.Export
  alias DevIDE.Workspace
  alias DevIDE.Workspaces
  alias DevIdeWeb.Plugs.AssignCurrentUser

  @default_filters %{
    "query" => "",
    "workspace" => "",
    "source" => "",
    "session" => "",
    "pane" => "",
    "since" => "",
    "until" => "",
    "limit" => "20"
  }

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

  @impl true
  def mount(%{"id" => id} = params, session, socket) do
    user = AssignCurrentUser.from_session(session)
    filters = params_to_filters(params)

    socket =
      socket
      |> assign(:page_title, "Previous Sessions")
      |> assign(:current_user, user)
      |> assign(:workspace_id, id)
      |> assign(:workspace, nil)
      |> assign(:filters, filters)
      |> assign(:form, search_form(filters))
      |> assign(:limit_options, @limit_options)
      |> assign(:source_options, @source_options)
      |> assign(:payload, empty_payload(id, filters))
      |> assign(:results, [])
      |> assign(:error, nil)

    case Workspaces.get(id, user[:email]) do
      {:ok, %Workspace{} = workspace} ->
        if connected?(socket) do
          :ok = Audit.subscribe(id)
          :ok = Activity.subscribe(id)
        end

        {:ok, socket |> assign(:workspace, workspace) |> refresh_results()}

      {:error, _reason} ->
        {:ok, assign(socket, :error, "Workspace not found.")}
    end
  end

  @impl true
  def handle_event("search", %{"search" => params}, socket) do
    filters = params_to_filters(params)

    socket =
      socket
      |> assign(:filters, filters)
      |> assign(:form, search_form(filters))
      |> refresh_results()

    {:noreply, socket}
  end

  def handle_event("search", params, socket) do
    handle_event("search", %{"search" => params}, socket)
  end

  def handle_event("clear", _params, socket) do
    filters = @default_filters

    socket =
      socket
      |> assign(:filters, filters)
      |> assign(:form, search_form(filters))
      |> refresh_results()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_mcp_activity, _entry}, socket),
    do: {:noreply, refresh_results(socket)}

  def handle_info({:audit_event, _event}, socket),
    do: {:noreply, refresh_results(socket)}

  defp refresh_results(%{assigns: %{workspace: nil}} = socket), do: socket

  defp refresh_results(socket) do
    filters = socket.assigns.filters

    case Export.previous_sessions(socket.assigns.workspace_id, search_opts(filters)) do
      {:ok, payload} ->
        socket
        |> assign(:payload, payload)
        |> assign(:results, Map.get(payload, :results, []))
        |> assign(:error, nil)

      :error ->
        assign(socket, :error, "Previous sessions are not available for this workspace.")
    end
  end

  defp params_to_filters(params) when is_map(params) do
    %{
      "query" => first_param(params, ["query", "q"]),
      "workspace" => first_param(params, ["workspace", "workspace_id", "workspace_name"]),
      "source" => first_param(params, ["source", "sources"]),
      "session" => first_param(params, ["session", "session_id"]),
      "pane" => first_param(params, ["pane", "pane_id"]),
      "since" => first_param(params, ["since", "from"]),
      "until" => first_param(params, ["until", "to"]),
      "limit" => normalize_limit(first_param(params, ["limit"]))
    }
  end

  defp params_to_filters(_params), do: @default_filters

  defp first_param(params, keys) do
    keys
    |> Enum.find_value("", fn key ->
      case Map.get(params, key) do
        value when is_binary(value) -> String.trim(value)
        value when is_integer(value) -> Integer.to_string(value)
        _ -> nil
      end
    end)
  end

  defp normalize_limit(value) when value in ["10", "20", "50"], do: value
  defp normalize_limit(""), do: @default_filters["limit"]
  defp normalize_limit(_value), do: @default_filters["limit"]

  defp search_opts(filters) do
    [
      query: filters["query"],
      workspace: filters["workspace"],
      source: filters["source"],
      session: filters["session"],
      pane: filters["pane"],
      since: filters["since"],
      until: filters["until"],
      limit: filters["limit"]
    ]
  end

  defp search_form(filters), do: Phoenix.Component.to_form(filters, as: :search)

  defp empty_payload(workspace_id, filters) do
    %{
      workspace_id: workspace_id,
      query: filters["query"],
      workspace: blank_to_nil(filters["workspace"]),
      source: blank_to_nil(filters["source"]),
      limit: String.to_integer(filters["limit"]),
      results: []
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="previous-sessions-page" class="space-y-5">
        <header class="space-y-3">
          <.link
            navigate={~p"/workspaces/#{@workspace_id}"}
            class="inline-flex items-center gap-1 text-xs font-medium text-zinc-600 transition hover:text-zinc-950"
          >
            <.icon name="hero-arrow-left" class="size-3.5" /> Workspace
          </.link>
          <div class="space-y-1">
            <h1 class="text-2xl font-semibold tracking-tight text-zinc-950">
              Previous Sessions
            </h1>
            <p class="text-sm text-zinc-500">
              {workspace_label(@workspace)}
            </p>
          </div>
        </header>

        <%= if @error do %>
          <div
            id="previous-sessions-error"
            class="rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-800"
          >
            {@error}
          </div>
        <% else %>
          <.form
            id="previous-sessions-search"
            for={@form}
            phx-change="search"
            phx-submit="search"
            class="rounded border border-zinc-200 bg-white p-4 shadow-sm"
          >
            <div class="grid gap-3 sm:grid-cols-2">
              <div class="sm:col-span-2">
                <.input
                  field={@form[:query]}
                  type="search"
                  label="Prompt text"
                  placeholder="Search prompts, commands, titles"
                  phx-debounce="350"
                  class="mt-1 block w-full rounded border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-950 shadow-sm transition focus:border-zinc-500 focus:outline-none focus:ring-2 focus:ring-zinc-200"
                />
              </div>
              <.input
                field={@form[:workspace]}
                type="text"
                label="Workspace"
                placeholder={@workspace_id}
                phx-debounce="350"
                class="mt-1 block w-full rounded border border-zinc-300 bg-white px-3 py-2 font-mono text-sm text-zinc-950 shadow-sm transition focus:border-zinc-500 focus:outline-none focus:ring-2 focus:ring-zinc-200"
              />
              <.input
                field={@form[:source]}
                type="select"
                label="Source"
                options={@source_options}
                class="mt-1 block w-full rounded border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-950 shadow-sm transition focus:border-zinc-500 focus:outline-none focus:ring-2 focus:ring-zinc-200"
              />
              <.input
                field={@form[:session]}
                type="text"
                label="Session"
                placeholder="api-session"
                phx-debounce="350"
                class="mt-1 block w-full rounded border border-zinc-300 bg-white px-3 py-2 font-mono text-sm text-zinc-950 shadow-sm transition focus:border-zinc-500 focus:outline-none focus:ring-2 focus:ring-zinc-200"
              />
              <.input
                field={@form[:pane]}
                type="text"
                label="Pane"
                placeholder="%3"
                phx-debounce="350"
                class="mt-1 block w-full rounded border border-zinc-300 bg-white px-3 py-2 font-mono text-sm text-zinc-950 shadow-sm transition focus:border-zinc-500 focus:outline-none focus:ring-2 focus:ring-zinc-200"
              />
              <.input
                field={@form[:since]}
                type="date"
                label="Since"
                phx-debounce="350"
                class="mt-1 block w-full rounded border border-zinc-300 bg-white px-3 py-2 font-mono text-sm text-zinc-950 shadow-sm transition focus:border-zinc-500 focus:outline-none focus:ring-2 focus:ring-zinc-200"
              />
              <.input
                field={@form[:until]}
                type="date"
                label="Until"
                phx-debounce="350"
                class="mt-1 block w-full rounded border border-zinc-300 bg-white px-3 py-2 font-mono text-sm text-zinc-950 shadow-sm transition focus:border-zinc-500 focus:outline-none focus:ring-2 focus:ring-zinc-200"
              />
              <.input
                field={@form[:limit]}
                type="select"
                label="Limit"
                options={@limit_options}
                class="mt-1 block w-full rounded border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-950 shadow-sm transition focus:border-zinc-500 focus:outline-none focus:ring-2 focus:ring-zinc-200"
              />
            </div>

            <div class="mt-3 flex justify-end">
              <button
                id="previous-sessions-clear"
                type="button"
                phx-click="clear"
                class="inline-flex items-center gap-1 rounded border border-zinc-300 bg-white px-2.5 py-1.5 text-xs font-medium text-zinc-700 transition hover:bg-zinc-50"
              >
                <.icon name="hero-x-mark" class="size-3.5" /> Clear
              </button>
            </div>
          </.form>

          <section id="previous-sessions-results" class="space-y-3">
            <div class="flex items-center justify-between gap-3 text-xs text-zinc-500">
              <span id="previous-sessions-count">
                {result_count_label(@results)}
              </span>
              <span class="font-mono">limit {@payload.limit}</span>
            </div>

            <%= if @results == [] do %>
              <div
                id="previous-sessions-empty"
                class="rounded border border-zinc-200 bg-zinc-50 px-4 py-6 text-sm text-zinc-500"
              >
                No matching session context.
              </div>
            <% else %>
              <ol class="space-y-3">
                <%= for result <- @results do %>
                  <li
                    id={"previous-session-" <> dom_id(result)}
                    class="rounded border border-zinc-200 bg-white p-4 shadow-sm"
                  >
                    <div class="flex flex-wrap items-center gap-2">
                      <span class="rounded bg-zinc-100 px-2 py-0.5 font-mono text-[11px] text-zinc-700">
                        {source_label(result.source)}
                      </span>
                      <%= if status = result_status(result) do %>
                        <span class={status_badge_class(status)}>
                          {status}
                        </span>
                      <% end %>
                      <%= if result.occurred_at do %>
                        <time class="font-mono text-[11px] text-zinc-500">
                          {format_time(result.occurred_at)}
                        </time>
                      <% end %>
                      <%= if href = result_href(result) do %>
                        <.link
                          navigate={href}
                          class="ml-auto inline-flex items-center gap-1 rounded border border-zinc-200 px-2 py-0.5 text-[11px] font-medium text-zinc-700 transition hover:bg-zinc-50"
                        >
                          <.icon name="hero-arrow-top-right-on-square" class="size-3" /> Open
                        </.link>
                      <% end %>
                    </div>

                    <h2 class="mt-2 text-sm font-semibold text-zinc-950">
                      {result.title}
                    </h2>
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
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp workspace_label(%Workspace{name: name, user: user}) do
    [name, user]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" / ")
  end

  defp workspace_label(_), do: "Workspace"

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
      "rounded border border-amber-200 bg-amber-50 px-2 py-0.5 text-[11px] font-medium text-amber-800"

  defp status_badge_class("Error"),
    do: "rounded border border-red-200 bg-red-50 px-2 py-0.5 text-[11px] font-medium text-red-700"

  defp status_badge_class("Done"),
    do:
      "rounded border border-emerald-200 bg-emerald-50 px-2 py-0.5 text-[11px] font-medium text-emerald-700"

  defp status_badge_class(_status),
    do:
      "rounded border border-zinc-200 bg-zinc-50 px-2 py-0.5 text-[11px] font-medium text-zinc-700"

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
