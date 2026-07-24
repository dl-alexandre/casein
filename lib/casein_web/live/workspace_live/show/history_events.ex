defmodule CaseinWeb.WorkspaceLive.Show.HistoryEvents do
  # Previous-session History panel state + handle_event clauses, delegated from
  # CaseinWeb.WorkspaceLive.Show (mirrors FileEvents/LogsEvents). Absorbs the
  # former WorkspaceLive.PreviousSessions full-page LiveView into the cockpit.
  #
  # Lazy by construction: mount only seeds empty defaults (`assign_defaults/1`);
  # the bounded `Casein.Export.previous_sessions/2` search runs the first time
  # the History tab opens (`open/2`), never during cockpit mount. Every search
  # is scoped to the mounted workspace id from the socket — the client-supplied
  # "workspace" form field is only a *filter within* that workspace's results
  # (see `Casein.Export.WorkspaceStatus.previous_sessions/2`).
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView, only: [connected?: 1]

  alias Casein.Agents.Activity
  alias Casein.Audit
  alias Casein.Export
  alias CaseinWeb.Forms.PreviousSessionsSearch

  # Old /workspaces/:id/previous-sessions URLs carried these search params
  # (plus the aliases PreviousSessionsSearch accepts); the legacy redirect
  # preserves them, so seed the panel filters when any is present.
  @seed_params ~w(query q workspace workspace_id workspace_name source sources
                  session session_id pane pane_id since from until to limit)

  # --- state -----------------------------------------------------------------

  @doc "Empty panel state assigned during cockpit mount. No domain calls."
  def assign_defaults(socket) do
    socket
    |> assign(:history_loaded?, false)
    |> assign(:history_subscribed?, false)
    |> assign(:history_error, nil)
    |> assign(:history_results, [])
    |> apply_changeset(PreviousSessionsSearch.from_params(%{}))
  end

  @doc """
  Open the History tab: seed filters from deep-link params (when present) and
  run the first search. Only the connected mount performs domain calls — the
  static render shows the loading state.
  """
  def open(socket, params \\ %{}) do
    socket = maybe_seed_filters(socket, params)

    if connected?(socket) do
      socket
      |> subscribe_once()
      |> refresh()
      |> assign(:history_loaded?, true)
    else
      socket
    end
  end

  @doc "Live refresh from audit/MCP-activity broadcasts, only while the panel is open."
  def refresh_if_open(%{assigns: %{tab: "history", history_loaded?: true}} = socket),
    do: refresh(socket)

  def refresh_if_open(socket), do: socket

  # --- handle_event ----------------------------------------------------------

  def handle_event("history:search", %{"search" => params}, socket) when is_map(params) do
    socket =
      socket
      |> apply_changeset(PreviousSessionsSearch.from_params(params))
      |> refresh()

    {:noreply, socket}
  end

  def handle_event("history:search", params, socket) when is_map(params) do
    handle_event("history:search", %{"search" => params}, socket)
  end

  def handle_event("history:clear", _params, socket) do
    socket =
      socket
      |> apply_changeset(PreviousSessionsSearch.from_params(%{}))
      |> refresh()

    {:noreply, socket}
  end

  def handle_event("history:refresh", _params, socket) do
    {:noreply, refresh(socket)}
  end

  # --- internals ---------------------------------------------------------------

  defp refresh(socket) do
    filters = socket.assigns.history_filters
    # Always the mounted workspace — never a client-supplied id.
    workspace_id = socket.assigns.workspace.id

    case Export.previous_sessions(workspace_id, PreviousSessionsSearch.search_opts(filters)) do
      {:ok, payload} ->
        socket
        |> assign(:history_payload, payload)
        |> assign(:history_results, Map.get(payload, :results, []))
        |> assign(:history_error, nil)

      :error ->
        assign(socket, :history_error, "Previous sessions are not available for this workspace.")
    end
  end

  defp subscribe_once(%{assigns: %{history_subscribed?: true}} = socket), do: socket

  defp subscribe_once(socket) do
    workspace_id = socket.assigns.workspace.id
    :ok = Audit.subscribe(workspace_id)
    :ok = Activity.subscribe(workspace_id)
    assign(socket, :history_subscribed?, true)
  end

  defp maybe_seed_filters(socket, params) when is_map(params) do
    if Enum.any?(@seed_params, &Map.has_key?(params, &1)) do
      apply_changeset(socket, PreviousSessionsSearch.from_params(params))
    else
      socket
    end
  end

  defp apply_changeset(socket, changeset) do
    filters = PreviousSessionsSearch.to_filters(changeset)

    socket
    |> assign(:history_filters, filters)
    |> assign(:history_form, PreviousSessionsSearch.to_form(changeset))
    |> assign_new(:history_payload, fn -> %{limit: filters.limit, results: []} end)
  end
end
