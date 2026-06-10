defmodule DevIdeWeb.API.WorkspaceController do
  @moduledoc """
  Core workspace API: listing, status, topology snapshot, run history,
  run creation (immediate or runner-protocol), proposals, and audit export.

  Window, pane, and template endpoints live in their own controllers
  (`WorkspaceWindowController`, `WorkspacePaneController`,
  `WorkspaceTemplateController`) and share helpers via
  `DevIdeWeb.API.WorkspaceAPI`.
  """

  use DevIdeWeb, :controller

  import DevIdeWeb.API.WorkspaceAPI

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

  def topology(conn, %{"id" => id}) do
    with {:ok, _status} <- Export.status(id),
         {:ok, session} <- topology_session(conn) do
      json(conn, topology_payload(id, session))
    else
      :error -> not_found(conn)
      {:error, reason} -> rejected(conn, :unprocessable_entity, reason)
    end
  end

  def runs(conn, %{"id" => id}) do
    case Export.runs(id) do
      {:ok, list} -> json(conn, list)
      :error -> not_found(conn)
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

  # ---------------------------------------------------------------------------
  # Run creation

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
    with {:ok, metadata} <- validated_runner_metadata(conn, id, command_id),
         {:ok, assignment} <-
           Runners.enqueue_command(id, command_id,
             requested_by: "jx",
             metadata: metadata
           ) do
      conn
      |> put_status(:created)
      |> json(%{
        protocol: Runners.protocol(),
        assignment: Runners.assignment_payload(assignment)
      })
    else
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

  defp validated_runner_metadata(conn, workspace_id, command_id) do
    with {:ok, runtime} <- safe_runtime_request(workspace_id, runtime_request(conn)),
         {:ok, routing} <- safe_routing_requirements(workspace_id, routing_requirements(conn)) do
      {:ok, runner_assignment_metadata(conn, command_id, runtime, routing)}
    end
  end

  defp runner_assignment_metadata(conn, command_id, runtime, routing) do
    %{
      source: "api",
      trigger: "jx",
      protocol: Runners.protocol(),
      command_id: command_id,
      correlation_id: correlation_id(conn),
      jx_assignment_id: param(conn, "jx_assignment_id"),
      jx_action_id: param(conn, "jx_action_id"),
      jx_safe_action_kind: param(conn, "jx_safe_action_kind"),
      runtime: runtime,
      routing: routing
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}] end)
    |> Map.new()
  end

  defp safe_runtime_request(workspace_id, request) do
    safe_path_fields(workspace_id, request, ["runtime_path", "worktree_path"])
  end

  defp safe_routing_requirements(workspace_id, requirements) do
    safe_path_fields(workspace_id, requirements, ["runtime_path"])
  end

  defp safe_path_fields(workspace_id, map, keys) do
    Enum.reduce_while(keys, {:ok, map}, fn key, {:ok, acc} ->
      case Map.get(acc, key) do
        nil ->
          {:cont, {:ok, acc}}

        "" ->
          {:cont, {:ok, acc}}

        path ->
          case resolve_workspace_path(workspace_id, path) do
            {:ok, resolved} -> {:cont, {:ok, Map.put(acc, key, resolved)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
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
end
