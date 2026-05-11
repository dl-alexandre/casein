defmodule DevIdeWeb.API.WorkspaceController do
  use DevIdeWeb, :controller

  alias DevIDE.Commands.Rerun
  alias DevIDE.Export
  alias DevIDE.Runners

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
end
