defmodule Casein.Terminals.WorkerCancel do
  @moduledoc """
  Operator-visible **worker cancel** (#384 M4.1).

  Inverse of `WorkerLaunch`: one call that tears down a Casein-managed worker
  window and returns a structured receipt. Completes the M4-lite launch verb
  with the matching teardown — the live pain after #904 is that orchestrators
  can spawn a visible worker but cannot retire it without raw `kill-window`.

  ## Fail closed

    * missing/invalid `workspace_id`, `session`, or `pane`
    * pane not found in the session
    * target is not a worker (`fleet_role` / `worker-<slug>` window)
    * manager, operator, or unlabeled pane
    * caller's own window
    * missing / non-`@N` window id (never kill by index — tmux renumbers)
    * last window in the session (would destroy the session)
    * kill failure

  ## Out of scope (leave #384 open)

  Durable task graph, path contracts, verifier adapters, `worker_replace`,
  `worker_send_contract`, restricted orchestrator token profile rewrite.

  ## Constraints carried in this module (not only in briefs)

  Briefs die with the pane. Do **not** "helpfully" undo these:

  * **dry_run never claims the worker is gone** — `cancelled?: false` and
    `visible?: true`. Operators treat `cancelled?: true` as proof the window
    died (#904 inverse: do not set `pane_id` / `visible?: true` on launch
    dry_run).
  * **`cancelled?: true` only after the killer returns `:ok`** — never a
    WindowTrash hide-while-alive path. Hiding is not cancel.
  * **Kill by window id (`@N`), never window index** — tmux renumbers remaining
    windows after each close.
  * **No durable graph / path contracts / verifiers here.**
  * **Do not edit `pane_submit.ex` from this lane.**
  * **Do not widen Backend/Fake adapter surface from this lane** — inject
    `:observe` / `:killer` in tests.
  """

  alias Casein.Terminals.Backend
  alias Casein.Terminals.FleetChrome
  alias Casein.Terminals.WorkHandles
  alias Casein.Terminals.WorkerStatus

  @window_id_re ~r/\A@\d+\z/

  @type receipt :: %{
          required(:ok) => true,
          required(:workspace_id) => String.t(),
          required(:session) => String.t(),
          required(:pane_id) => String.t(),
          required(:window_id) => String.t(),
          required(:cancelled?) => boolean(),
          required(:visible?) => boolean(),
          optional(:window_name) => String.t(),
          optional(:handle_id) => String.t(),
          optional(:dry_run) => true,
          optional(:note) => String.t()
        }

  @doc """
  Cancel a visible worker window and return a structured receipt.

  Options:

    * `:workspace_id` / `:session` / `:pane` — required
    * `:window_id` — optional disambiguator (must still resolve to `@N`)
    * `:handle_id` — optional; recorded as `cancelled` after a live kill
    * `:caller_pane` — refuse when the target is the caller's own window
    * `:dry_run` — classify and plan only; never kills
    * `:observe` — `(session, pane_id, window_id -> {:ok, map()} | {:error, term()})`
    * `:killer` — `(session, window_id -> :ok | {:error, term()})` for tests
    * `:topology` — enriched topology used by the default observer
    * `:record_handle` — when true (default), record handle status after kill
  """
  @spec cancel(keyword()) :: {:ok, receipt() | map()} | {:error, map()}
  def cancel(opts) when is_list(opts) do
    with {:ok, workspace_id} <- fetch_bin(opts, :workspace_id),
         {:ok, session} <- fetch_bin(opts, :session),
         {:ok, pane_id} <- fetch_bin(opts, :pane) do
      window_id = blank_to_nil(Keyword.get(opts, :window_id))
      observe = Keyword.get(opts, :observe, &default_observe(&1, &2, &3, opts))

      case observe.(session, pane_id, window_id) do
        {:ok, facts} when is_map(facts) ->
          decide(workspace_id, session, pane_id, facts, opts)

        {:error, reason} ->
          {:error, normalize_error(reason)}

        other ->
          {:error,
           %{
             error: :invalid_observe_result,
             detail: inspect(other),
             message: "observe returned no worker facts"
           }}
      end
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  def cancel(_), do: {:error, %{error: :invalid_options}}

  ## Decide

  defp decide(workspace_id, session, pane_id, facts, opts) do
    dry_run? = Keyword.get(opts, :dry_run, false) == true
    caller_pane = blank_to_nil(Keyword.get(opts, :caller_pane))

    with {:ok, resolved_id} <- fetch_window_id(facts),
         :ok <- refuse_index(resolved_id),
         :ok <- refuse_not_worker(facts),
         :ok <- refuse_same_window(facts, caller_pane, pane_id),
         :ok <- refuse_last_window(facts) do
      if dry_run? do
        # do not set cancelled?: true or visible?: false on dry_run — operators
        # treat those as proof the worker is gone (#384 M4.1; dry_run is plan-only).
        {:ok,
         %{
           ok: true,
           dry_run: true,
           workspace_id: workspace_id,
           session: session,
           pane_id: pane_id,
           window_id: resolved_id,
           window_name: Map.get(facts, :window_name),
           cancelled?: false,
           visible?: true,
           note: "Dry run only — no window killed. Re-call without dry_run to cancel this worker."
         }
         |> maybe_put_handle(opts)
         |> reject_nils()}
      else
        live_kill(workspace_id, session, pane_id, resolved_id, facts, opts)
      end
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp live_kill(workspace_id, session, pane_id, window_id, facts, opts) do
    killer = Keyword.get(opts, :killer, &default_killer/2)

    case killer.(session, window_id) do
      :ok ->
        receipt =
          %{
            ok: true,
            workspace_id: workspace_id,
            session: session,
            pane_id: pane_id,
            window_id: window_id,
            window_name: Map.get(facts, :window_name),
            cancelled?: true,
            visible?: false,
            note:
              "M4.1 worker_cancel receipt. Window killed by window_id (@N), not index. " <>
                "cancelled? means the window is gone — not hidden. " <>
                "Durable task graph / path contracts / verifiers / worker_replace remain out of scope."
          }
          |> maybe_put_handle(opts)
          |> reject_nils()

        maybe_record_handle(receipt, opts)
        {:ok, receipt}

      {:error, reason} ->
        {:error, normalize_error(reason)}

      other ->
        {:error,
         %{
           error: :kill_failed,
           detail: inspect(other),
           message: "killer did not return :ok"
         }}
    end
  end

  ## Guards

  defp fetch_window_id(facts) do
    case blank_to_nil(Map.get(facts, :window_id) || Map.get(facts, "window_id")) do
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, %{error: :missing_window_id, message: "cannot cancel without a window id"}}
    end
  end

  defp refuse_index(window_id) do
    if Regex.match?(@window_id_re, window_id) do
      :ok
    else
      {:error,
       %{
         error: :invalid_window_id,
         window_id: window_id,
         message: "kill by window id (@N) only — tmux renumbers indices"
       }}
    end
  end

  defp refuse_not_worker(facts) do
    role = classify_role(facts)

    cond do
      role == :worker ->
        :ok

      role == :manager ->
        {:error,
         %{
           error: :not_a_worker,
           fleet_role: "manager",
           message: "refusing to cancel a manager pane"
         }}

      true ->
        {:error,
         %{
           error: :not_a_worker,
           fleet_role: role && to_string(role),
           message: "refusing to cancel a non-worker pane"
         }}
    end
  end

  defp classify_role(facts) do
    explicit = normalize_role(Map.get(facts, :fleet_role) || Map.get(facts, "fleet_role"))

    explicit ||
      FleetChrome.role_from_text(Map.get(facts, :window_name) || Map.get(facts, "window_name")) ||
      FleetChrome.role_from_text(Map.get(facts, :label) || Map.get(facts, "label"))
  end

  defp normalize_role(:worker), do: :worker
  defp normalize_role(:manager), do: :manager
  defp normalize_role("worker"), do: :worker
  defp normalize_role("manager"), do: :manager
  defp normalize_role(_), do: nil

  defp refuse_same_window(facts, caller_pane, target_pane) do
    caller_window =
      blank_to_nil(Map.get(facts, :caller_window_id) || Map.get(facts, "caller_window_id"))

    target_window = blank_to_nil(Map.get(facts, :window_id) || Map.get(facts, "window_id"))

    cond do
      is_binary(caller_pane) and caller_pane == target_pane ->
        {:error, %{error: :same_window, message: "refusing to cancel the caller's own pane"}}

      is_binary(caller_window) and is_binary(target_window) and caller_window == target_window ->
        {:error, %{error: :same_window, message: "refusing to cancel the caller's own window"}}

      true ->
        :ok
    end
  end

  defp refuse_last_window(facts) do
    case Map.get(facts, :window_count) || Map.get(facts, "window_count") do
      n when is_integer(n) and n > 1 ->
        :ok

      n when is_integer(n) ->
        {:error,
         %{
           error: :last_window,
           window_count: n,
           message: "refusing to kill the last window in the session"
         }}

      _ ->
        {:error,
         %{
           error: :unknown_window_count,
           message: "refusing to cancel without a known session window count"
         }}
    end
  end

  ## Observe / kill

  defp default_observe(session, pane_id, window_id, opts) do
    case Keyword.get(opts, :topology) do
      %{} = topology ->
        facts_from_topology(topology, pane_id, window_id, opts)

      _ ->
        facts_from_backend(session, pane_id, window_id, opts)
    end
  end

  defp facts_from_topology(topology, pane_id, window_id, opts) do
    case WorkerStatus.find_pane(topology, pane_id, window_id) do
      nil ->
        {:error, %{error: :pane_not_found, pane: pane_id}}

      pane ->
        windows = topology_windows(topology)
        window = window_for(pane, windows)
        caller_pane = blank_to_nil(Keyword.get(opts, :caller_pane))

        {:ok,
         %{
           pane_id: pane_field(pane, :id),
           window_id: pane_field(pane, :window_id) || window_field(window, :id),
           window_name:
             pane_field(pane, :window_name) || window_field(window, :name) ||
               window_field(window, "name"),
           fleet_role: pane_field(pane, :fleet_role) || window_field(window, :fleet_role),
           label: pane_field(pane, :label),
           window_count: length(windows),
           caller_window_id: caller_window_id(topology, caller_pane)
         }}
    end
  end

  defp facts_from_backend(session, pane_id, window_id, opts) do
    tmux = Backend.module()

    panes =
      try do
        tmux.list_session_panes(session)
      rescue
        _ -> []
      end

    pane =
      Enum.find(panes, fn p ->
        id = pane_field(p, :id)
        id == pane_id and (is_nil(window_id) or pane_field(p, :window_id) == window_id)
      end)

    if is_nil(pane) do
      {:error, %{error: :pane_not_found, pane: pane_id}}
    else
      windows =
        try do
          tmux.list_session_windows(session)
        rescue
          _ -> []
        end

      window =
        Enum.find(windows, fn w ->
          window_field(w, :id) == pane_field(pane, :window_id)
        end)

      caller_pane = blank_to_nil(Keyword.get(opts, :caller_pane))

      {:ok,
       %{
         pane_id: pane_field(pane, :id),
         window_id: pane_field(pane, :window_id) || window_field(window, :id),
         window_name: window_field(window, :name) || pane_field(pane, :window_name),
         fleet_role: pane_field(pane, :fleet_role),
         label: pane_field(pane, :label),
         window_count: length(windows),
         caller_window_id: caller_window_from_panes(panes, caller_pane)
       }}
    end
  end

  defp topology_windows(%{windows: windows}) when is_list(windows), do: windows
  defp topology_windows(%{"windows" => windows}) when is_list(windows), do: windows
  defp topology_windows(_), do: []

  defp window_for(pane, windows) do
    wid = pane_field(pane, :window_id)

    Enum.find(windows, fn window ->
      window_field(window, :id) == wid
    end)
  end

  defp caller_window_id(_topology, nil), do: nil

  defp caller_window_id(topology, caller_pane) do
    case WorkerStatus.find_pane(topology, caller_pane, nil) do
      nil -> nil
      pane -> pane_field(pane, :window_id)
    end
  end

  defp caller_window_from_panes(_panes, nil), do: nil

  defp caller_window_from_panes(panes, caller_pane) do
    case Enum.find(panes, &(pane_field(&1, :id) == caller_pane)) do
      nil -> nil
      pane -> pane_field(pane, :window_id)
    end
  end

  defp default_killer(session, window_id) do
    Backend.module().kill_window(session, window_id)
  end

  ## Handles

  defp maybe_put_handle(receipt, opts) do
    case blank_to_nil(Keyword.get(opts, :handle_id)) do
      id when is_binary(id) -> Map.put(receipt, :handle_id, id)
      _ -> receipt
    end
  end

  defp maybe_record_handle(receipt, opts) do
    handle_id = blank_to_nil(Keyword.get(opts, :handle_id) || Map.get(receipt, :handle_id))

    if handle_id && Keyword.get(opts, :record_handle, true) do
      _ = safe_record_status(handle_id)
    end

    :ok
  end

  defp safe_record_status(handle_id) do
    WorkHandles.record_status(handle_id, "cancelled", "cancelled via worker_cancel")
  catch
    :exit, _ -> {:error, :work_handles_unavailable}
  end

  ## Small helpers

  defp fetch_bin(opts, key) do
    case Keyword.get(opts, key) do
      v when is_binary(v) ->
        v = String.trim(v)

        if v == "",
          do: {:error, %{error: :missing_argument, argument: to_string(key)}},
          else: {:ok, v}

      _ ->
        {:error, %{error: :missing_argument, argument: to_string(key)}}
    end
  end

  defp pane_field(nil, _key), do: nil

  defp pane_field(pane, key) when is_map(pane) do
    Map.get(pane, key) || Map.get(pane, Atom.to_string(key))
  end

  defp window_field(nil, _key), do: nil

  defp window_field(window, key) when is_map(window) do
    Map.get(window, key) || Map.get(window, Atom.to_string(key))
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s
  defp blank_to_nil(_), do: nil

  defp normalize_error(%{} = err), do: err
  defp normalize_error(atom) when is_atom(atom), do: %{error: atom}
  defp normalize_error({:missing_argument, key}), do: %{error: :missing_argument, argument: key}
  defp normalize_error(other), do: %{error: :cancel_failed, detail: inspect(other)}

  defp reject_nils(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
