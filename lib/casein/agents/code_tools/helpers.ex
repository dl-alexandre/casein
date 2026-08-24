defmodule Casein.Agents.CodeTools.Helpers do
  @moduledoc """
  Shared JSON-Schema fragments, worktree assignment, and path guards for
  the Code MCP tools.
  """

  alias Casein.Files.PathSafety
  alias Casein.Policy
  alias Casein.Policy.Decision
  alias Casein.Runtimes
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.WorkspaceRecord

  @max_read_bytes 256 * 1024
  @max_search_matches 200
  @default_search_matches 50
  @max_output_bytes 256 * 1024
  @default_output_bytes 64 * 1024
  @max_timeout_ms 120_000
  @default_timeout_ms 30_000

  @doc false
  def workspace_id_param do
    %{
      type: "string",
      description: "Casein workspace id. Pre-scoped Code MCP endpoints inject this automatically."
    }
  end

  @doc false
  def worktree_path_param do
    %{
      type: "string",
      description:
        "Absolute or workspace-relative path of the assigned Git worktree. " <>
          "Must be the workspace checkout or a registered agent worktree for this workspace."
    }
  end

  @doc false
  def path_param do
    %{
      type: "string",
      description:
        "Repository-relative path inside the assigned worktree. Absolute paths, " <>
          "backslashes, NULs, traversal, and .git are rejected."
    }
  end

  @doc false
  def identity_params do
    %{
      task_id: %{
        type: "string",
        description: "Optional durable task id stamped onto audit/activity."
      },
      attempt_id: %{
        type: "string",
        description: "Optional attempt/correlation id stamped onto audit/activity."
      }
    }
  end

  @doc false
  def metadata(danger_level, mutating?) do
    %{
      mutation?: mutating?,
      danger_level: danger_level,
      capabilities: [:code],
      recovery_hints: [
        "Pass worktree_path for the assigned attempt worktree.",
        "Use repository-relative paths only — no absolute paths or .. segments."
      ]
    }
  end

  @doc false
  def max_read_bytes, do: @max_read_bytes

  @doc false
  def clamp_search_limit(value),
    do: clamp_int(value, 1, @max_search_matches, @default_search_matches)

  @doc false
  def clamp_output_bytes(value),
    do: clamp_int(value, 1, @max_output_bytes, @default_output_bytes)

  @doc false
  def clamp_timeout_ms(value), do: clamp_int(value, 1, @max_timeout_ms, @default_timeout_ms)

  @doc "Resolve workspace + assigned worktree for a tool call."
  @spec resolve_assignment(map(), map()) :: {:ok, map()} | {:error, term()}
  def resolve_assignment(params, context \\ %{}) when is_map(params) do
    workspace_id = Map.get(params, :workspace_id) || Map.get(params, "workspace_id")

    with {:ok, record} <- fetch_workspace(workspace_id),
         {:ok, worktree_path} <- resolve_worktree(record, worktree_path(params)) do
      {:ok,
       %{
         workspace_id: record.external_id,
         record: record,
         worktree_path: worktree_path,
         actor_id: actor_id(params, context),
         task_id: optional_string(params, :task_id),
         attempt_id: optional_string(params, :attempt_id)
       }}
    end
  end

  @doc "Policy context derived from the assignment and MCP actor."
  @spec policy_ctx(map()) :: Policy.ctx()
  def policy_ctx(%{workspace_id: workspace_id, record: record} = assignment) do
    %{
      workspace_id: workspace_id,
      actor_id: assignment.actor_id,
      actor_type: :agent,
      db_isolation: db_isolation(record)
    }
  end

  @doc "Run a Policy check and return a structured denial when blocked."
  @spec authorize((Policy.ctx() -> Decision.t()), map()) :: :ok | {:error, map()}
  def authorize(fun, assignment) when is_function(fun, 1) do
    decision = fun.(policy_ctx(assignment))

    if Decision.allow?(decision) do
      :ok
    else
      {:error,
       %{
         error: :policy_denied,
         action: decision.action,
         reason: decision.reason,
         mode: decision.mode,
         message: "Policy denied #{decision.action} (#{decision.reason})"
       }}
    end
  end

  @doc "Resolve a repository-relative path inside the assigned worktree."
  @spec resolve_rel_path(String.t(), String.t()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def resolve_rel_path(worktree_path, relative) when is_binary(worktree_path) do
    case normalize_rel_path(relative) do
      {:ok, rel} ->
        case PathSafety.resolve(worktree_path, rel) do
          {:ok, abs} -> {:ok, rel, abs}
          {:error, reason} -> {:error, path_error(reason, rel)}
        end

      {:error, _} = err ->
        err
    end
  end

  def resolve_rel_path(_worktree_path, _relative), do: {:error, path_error(:missing_path, nil)}

  @doc "Normalize and reject unsafe repository-relative paths before resolution."
  @spec normalize_rel_path(term()) :: {:ok, String.t()} | {:error, map()}
  def normalize_rel_path(relative) when is_binary(relative) do
    cond do
      String.trim(relative) == "" ->
        {:error, path_error(:missing_path, relative)}

      String.contains?(relative, <<0>>) ->
        {:error, path_error(:nul_in_path, relative)}

      String.contains?(relative, "\\") ->
        {:error, path_error(:backslash_in_path, relative)}

      Path.type(relative) == :absolute ->
        {:error, path_error(:absolute_path, relative)}

      PathSafety.ignored?(relative) ->
        {:error, path_error(:path_not_allowed, relative)}

      true ->
        {:ok, relative |> String.replace_leading("./", "") |> String.trim_leading("/")}
    end
  end

  def normalize_rel_path(_relative), do: {:error, path_error(:missing_path, nil)}

  @doc false
  def identity_fields(assignment) do
    %{
      workspace_id: assignment.workspace_id,
      worktree_path: assignment.worktree_path,
      task_id: assignment.task_id,
      attempt_id: assignment.attempt_id
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  @doc false
  def truncate_bytes(binary, max_bytes) when is_binary(binary) and is_integer(max_bytes) do
    if byte_size(binary) <= max_bytes do
      {binary, false}
    else
      {binary_part(binary, 0, max_bytes), true}
    end
  end

  defp fetch_workspace(id) when is_binary(id) and id != "" do
    case State.get(id) do
      {:ok, %WorkspaceRecord{} = record} -> {:ok, record}
      :error -> {:error, %{error: :workspace_not_found, workspace_id: id}}
    end
  end

  defp fetch_workspace(_id), do: {:error, %{error: :missing_workspace_id}}

  defp resolve_worktree(%WorkspaceRecord{host_path: root} = record, requested)
       when is_binary(root) and root != "" do
    checkout = Path.expand(root)

    cond do
      not File.dir?(checkout) ->
        {:error, %{error: :workspace_root_unavailable, worktree_path: checkout}}

      requested in [nil, ""] ->
        {:error,
         %{
           error: :worktree_path_required,
           message: "Pass worktree_path for the assigned attempt worktree."
         }}

      true ->
        authorize_worktree(record, checkout, requested)
    end
  end

  defp resolve_worktree(_record, _requested),
    do: {:error, %{error: :workspace_root_unavailable}}

  defp authorize_worktree(record, checkout, requested) do
    path = expand_requested(checkout, requested)

    cond do
      not File.dir?(path) ->
        {:error, %{error: :worktree_not_found, worktree_path: path}}

      same_path?(path, checkout) ->
        {:ok, path}

      assigned_worktree?(record, path) ->
        {:ok, path}

      true ->
        {:error,
         %{
           error: :worktree_not_assigned,
           worktree_path: path,
           message: "worktree_path is not the workspace checkout or a registered agent worktree."
         }}
    end
  end

  defp assigned_worktree?(record, path) do
    # The workspace checkout itself is authorized by `authorize_worktree/3`.
    # A directory merely nested below it is not a Git worktree assignment and
    # must not become an implicit write boundary.
    registered_worktree?(record.external_id, path)
  end

  defp registered_worktree?(workspace_id, path) do
    canonical = canonicalize(path)

    workspace_id
    |> Runtimes.list_agent_worktrees()
    |> Enum.any?(fn entry ->
      candidate = Map.get(entry, :worktree_path) || Map.get(entry, "worktree_path")
      is_binary(candidate) and canonicalize(candidate) == canonical
    end)
  end

  defp expand_requested(checkout, requested) do
    case Path.type(requested) do
      :absolute -> Path.expand(requested)
      _ -> Path.expand(requested, checkout)
    end
  end

  defp same_path?(a, b), do: canonicalize(a) == canonicalize(b)

  defp canonicalize(path) do
    path
    |> Path.expand()
    |> String.trim_trailing("/")
  end

  defp worktree_path(params) do
    Map.get(params, :worktree_path) || Map.get(params, "worktree_path")
  end

  defp actor_id(params, context) do
    context[:actor] ||
      Map.get(params, :actor_id) ||
      Map.get(params, "actor_id")
  end

  defp optional_string(params, key) do
    case Map.get(params, key) || Map.get(params, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp db_isolation(%WorkspaceRecord{db_isolation: "shared_stage"}), do: :shared_stage
  defp db_isolation(%WorkspaceRecord{db_isolation: "unsafe"}), do: :unsafe

  defp db_isolation(%WorkspaceRecord{db_isolation: isolation})
       when isolation in ["ephemeral", "local"],
       do: :isolated

  defp db_isolation(_), do: nil

  defp clamp_int(value, min, max, _default) when is_integer(value) do
    value |> max(min) |> min(max)
  end

  defp clamp_int(_, _min, _max, default), do: default

  defp path_error(reason, path) do
    %{
      error: reason,
      path: path,
      message: path_message(reason)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp path_message(:missing_path), do: "A repository-relative path is required."
  defp path_message(:nul_in_path), do: "Paths may not contain NUL bytes."
  defp path_message(:backslash_in_path), do: "Paths may not contain backslashes."

  defp path_message(:absolute_path),
    do: "Absolute paths are rejected; use a repository-relative path."

  defp path_message(:path_not_allowed),
    do: "Paths under .git or other ignored trees are rejected."

  defp path_message(:outside_root), do: "Path is outside the assigned worktree."
  defp path_message(:symlink_escape), do: "Path escapes the assigned worktree via a symlink."
  defp path_message(:too_deep), do: "Path has too many segments."
  defp path_message(reason), do: "Invalid path (#{reason})."
end
