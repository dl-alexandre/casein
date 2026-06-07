defmodule DevIdeWeb.API.WorkspaceController do
  use DevIdeWeb, :controller

  alias DevIDE.Audit
  alias DevIDE.Commands.Rerun
  alias DevIDE.Export
  alias DevIDE.Runners
  alias DevIDE.Terminals.Tmux
  alias DevIDE.Terminals.TmuxTopology

  def index(conn, _params), do: json(conn, Export.list_summary())

  def status(conn, %{"id" => id}) do
    case Export.status(id) do
      {:ok, payload} -> json(conn, payload)
      :error -> not_found(conn)
    end
  end

  def runs(conn, %{"id" => id}) do
    case Export.runs(id) do
      {:ok, list} -> json(conn, list)
      :error -> not_found(conn)
    end
  end

  def topology(conn, %{"id" => id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn) do
      json(conn, topology_payload(id, session))
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def create_window(conn, %{"id" => id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn) do
      opts = window_create_opts(conn)

      mutate_window(conn, id, session, "window_created", fn ->
        tmux_adapter().new_window(session, opts)
      end)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def select_window(conn, %{"id" => id, "window_id" => window_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn) do
      mutate_window(conn, id, session, "window_selected", fn ->
        case find_window(session, window_id) do
          nil -> {:error, :window_not_found}
          _window -> tmux_adapter().select_window(session, window_id)
        end
      end)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def rename_window(conn, %{"id" => id, "window_id" => window_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn),
         {:ok, name} <- required_trimmed_param(conn, "name", "name_required") do
      mutate_window(conn, id, session, "window_renamed", fn ->
        case find_window(session, window_id) do
          nil -> {:error, :window_not_found}
          %{name: ^name} -> :ok
          _window -> tmux_adapter().rename_window(session, window_id, name)
        end
      end)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def kill_window(conn, %{"id" => id, "window_id" => window_id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn) do
      mutate_window(conn, id, session, "window_killed", fn ->
        case find_window(session, window_id) do
          nil -> {:error, :window_not_found}
          _window -> tmux_adapter().kill_window(session, window_id)
        end
      end)
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def run(conn, %{"id" => id, "run_id" => run_id}) do
    case Export.run(id, run_id) do
      {:ok, payload} -> json(conn, payload)
      :error -> not_found(conn)
    end
  end

  def create_run(conn, %{"id" => id, "command_id" => command_id}) when is_binary(command_id) do
    if Map.get(conn.params, "execution_protocol") == Runners.protocol() do
      create_runner_assignment(conn, id, command_id)
    else
      create_immediate_run(conn, id, command_id)
    end
  end

  def create_run(conn, _params), do: rejected(conn, :bad_request, "command_id_required")

  defp create_immediate_run(conn, id, command_id) do
    case Rerun.start(id, command_id, correlation_id: correlation_id(conn)) do
      {:ok, run} -> conn |> put_status(:created) |> json(run)
      {:error, :not_found} -> not_found(conn)
      {:error, :not_allowed} -> rejected(conn, :bad_request, "command_not_allowed")
      {:error, :shared_stage_guarded} -> rejected(conn, :forbidden, "unsafe_db_isolation")
      {:error, :unsafe_db} -> rejected(conn, :forbidden, "unsafe_db_isolation")
      {:error, :no_root} -> rejected(conn, :unprocessable_entity, "workspace_root_unavailable")
      {:error, :already_running} -> rejected(conn, :conflict, "command_already_running")
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  defp create_runner_assignment(conn, id, command_id) do
    case Runners.enqueue_command(id, command_id,
           requested_by: "jx",
           metadata: runner_assignment_metadata(conn, command_id)
         ) do
      {:ok, assignment} ->
        conn
        |> put_status(:created)
        |> json(%{
          protocol: Runners.protocol(),
          assignment: Runners.assignment_payload(assignment)
        })

      {:error, :not_found} ->
        not_found(conn)

      {:error, :safe_action_not_allowed} ->
        rejected(conn, :bad_request, "command_not_allowed")

      {:error, :shared_stage_guarded} ->
        rejected(conn, :forbidden, "unsafe_db_isolation")

      {:error, :unsafe_db} ->
        rejected(conn, :forbidden, "unsafe_db_isolation")

      {:error, reason} ->
        rejected(conn, :unprocessable_entity, reason)
    end
  end

  defp runner_assignment_metadata(conn, command_id) do
    %{
      source: "api",
      trigger: "jx",
      protocol: Runners.protocol(),
      command_id: command_id,
      correlation_id: correlation_id(conn),
      jx_assignment_id: param(conn, "jx_assignment_id"),
      jx_action_id: param(conn, "jx_action_id"),
      jx_safe_action_kind: param(conn, "jx_safe_action_kind"),
      runtime: runtime_request(conn),
      routing: routing_requirements(conn)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}] end)
    |> Map.new()
  end

  defp routing_requirements(conn) do
    requirements =
      case Map.get(conn.params, "runner_requirements") do
        map when is_map(map) -> map
        _ -> %{}
      end

    %{
      "host" => string_param(requirements, "host"),
      "os" => string_param(requirements, "os"),
      "repo" => string_param(requirements, "repo"),
      "branch_isolation" => string_param(requirements, "branch_isolation"),
      "runtime_id" => string_param(requirements, "runtime_id"),
      "runtime_path" => string_param(requirements, "runtime_path"),
      "tools" => string_list_param(requirements, "tools")
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp runtime_request(conn) do
    request =
      case Map.get(conn.params, "runtime") || Map.get(conn.params, "runtime_request") do
        map when is_map(map) -> map
        _ -> %{}
      end

    %{
      "runtime_id" => string_param(request, "runtime_id"),
      "runtime_path" => string_param(request, "runtime_path"),
      "worktree_path" => string_param(request, "worktree_path"),
      "host" => string_param(request, "host"),
      "host_id" => string_param(request, "host_id"),
      "os" => string_param(request, "os"),
      "repo" => string_param(request, "repo"),
      "branch" => string_param(request, "branch"),
      "branch_isolation" => string_param(request, "branch_isolation"),
      "isolation_mode" => string_param(request, "isolation_mode"),
      "tmux_session_id" => string_param(request, "tmux_session_id"),
      "session_id" => string_param(request, "session_id"),
      "tools" => string_list_param(request, "tools"),
      "capabilities" => string_list_param(request, "capabilities"),
      "concurrency_limit" => int_param(request, "concurrency_limit")
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp correlation_id(conn) do
    conn
    |> Plug.Conn.get_req_header("x-jx-correlation-id")
    |> List.first()
    |> case do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp param(conn, key) do
    case Map.get(conn.params, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp string_param(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp topology_session(conn) do
    case param(conn, "session") || param(conn, "tmux_session") do
      nil -> {:error, "session_required"}
      "" -> {:error, "session_required"}
      session -> {:ok, session}
    end
  end

  defp mutate_window(conn, workspace_id, session, action, fun) do
    if dry_run?(conn) do
      json(conn, %{
        action: action,
        dry_run: true,
        topology: topology_payload(workspace_id, session)
      })
    else
      case fun.() do
        :ok ->
          json(conn, mutation_payload(conn, workspace_id, session, action))

        {:ok, window_id} ->
          json(
            conn,
            mutation_payload(conn, workspace_id, session, action, %{window_id: window_id})
          )

        {:error, :window_not_found} ->
          rejected(conn, :not_found, "window_not_found")

        {:error, reason} ->
          rejected(conn, :unprocessable_entity, reason)
      end
    end
  end

  defp mutation_payload(conn, workspace_id, session, action, result \\ %{}) do
    _ = TmuxTopology.configure(session, workspace_id: workspace_id)
    _ = TmuxTopology.refresh(session)
    topology = topology_payload(workspace_id, session)
    emit_tmux_window_audit(conn, workspace_id, session, action, result, topology)

    %{
      action: action,
      dry_run: false,
      result: result,
      topology: topology
    }
  end

  defp topology_payload(workspace_id, session) do
    topology = TmuxTopology.snapshot(session, tmux: tmux_adapter())

    %{
      workspace_id: workspace_id,
      session: topology.session,
      active_window_id: topology.active_window_id,
      active_pane_id: topology.active_pane_id,
      version: topology.version,
      windows: topology.windows,
      panes: topology.panes
    }
  end

  defp find_window(session, window_id) do
    session
    |> TmuxTopology.snapshot(tmux: tmux_adapter())
    |> Map.fetch!(:windows)
    |> Enum.find(&(&1.id == window_id or to_string(&1.index) == window_id))
  end

  defp window_create_opts(conn) do
    []
    |> maybe_put_opt(:name, param(conn, "name"))
    |> maybe_put_opt(:cwd, param(conn, "cwd"))
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, _key, ""), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp required_trimmed_param(conn, key, error) do
    case param(conn, key) do
      nil -> {:error, error}
      "" -> {:error, error}
      value -> {:ok, value}
    end
  end

  defp dry_run?(conn) do
    Map.get(conn.params, "dry_run") in [true, "true", "1"]
  end

  defp emit_tmux_window_audit(conn, workspace_id, session, action, result, topology) do
    window_id =
      Map.get(result, :window_id) ||
        Map.get(result, "window_id") ||
        param(conn, "window_id") ||
        topology.active_window_id

    Audit.emit!(%{
      action: "tmux." <> action,
      workspace_id: workspace_id,
      actor_id: "api",
      target_type: "tmux_window",
      target_ref: window_id,
      metadata: %{
        session: session,
        window_id: window_id,
        active_window_id: topology.active_window_id,
        active_pane_id: topology.active_pane_id,
        topology_version: topology.version,
        dry_run: false
      }
    })
  end

  defp string_list_param(map, key) do
    case Map.get(map, key) do
      values when is_list(values) ->
        values
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp int_param(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def proposals(conn, %{"id" => id}) do
    case Export.proposals(id) do
      {:ok, list} -> json(conn, list)
      :error -> not_found(conn)
    end
  end

  def audit(conn, %{"id" => id}) do
    case Export.audit(id) do
      {:ok, list} -> json(conn, list)
      :error -> not_found(conn)
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found"})
  end

  defp rejected(conn, status, reason) do
    conn
    |> put_status(status)
    |> json(%{error: to_string(reason)})
  end

  defp tmux_adapter do
    Application.get_env(:dev_ide, :tmux_adapter, Tmux)
  end
end
