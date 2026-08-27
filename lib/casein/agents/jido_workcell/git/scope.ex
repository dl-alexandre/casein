defmodule Casein.Agents.JidoWorkcell.Git.Scope do
  @moduledoc """
  Trusted, immutable binding for a Jido worker's Git operations.

  A scope is created by the Casein coordinator. Worker-authored action
  arguments never replace it. The binding is deliberately narrower than a
  general Git client: one existing worktree, one assigned branch, and an
  explicit file allowlist.
  """

  alias Casein.Files.PathSafety
  alias Casein.Agents.JidoWorkcell.{Limits, OwnerRef}

  @default_branch "master"
  @protected_branches ~w(main master develop production staging release trunk)
  @max_paths Casein.Agents.JidoWorkcell.Limits.max_paths()
  @max_path_bytes 512

  @enforce_keys [:repository, :worktree_path, :base_branch, :assigned_branch]
  defstruct [
    :repository,
    :worktree_path,
    :base_branch,
    :assigned_branch,
    :default_branch,
    :workspace_id,
    :owner_ref,
    :runtime_id,
    :worker_id,
    :release_sha,
    :allowed_paths,
    :protected_branches,
    :worktree_root,
    push_allowed?: false
  ]

  @type t :: %__MODULE__{
          repository: String.t(),
          worktree_path: String.t(),
          base_branch: String.t(),
          assigned_branch: String.t(),
          default_branch: String.t(),
          workspace_id: String.t() | nil,
          owner_ref: OwnerRef.t() | nil,
          runtime_id: String.t() | nil,
          worker_id: String.t() | nil,
          release_sha: String.t() | nil,
          allowed_paths: [String.t()],
          protected_branches: [String.t()],
          worktree_root: String.t() | nil,
          push_allowed?: boolean()
        }

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) do
    with {:ok, repository} <- required_string(attrs, :repository),
         :ok <- safe_repository?(repository),
         {:ok, worktree_path} <- required_path(attrs, :worktree_path),
         {:ok, base_branch} <- branch(attrs, :base_branch, @default_branch),
         {:ok, assigned_branch} <- branch(attrs, :assigned_branch, nil),
         {:ok, default_branch} <- branch(attrs, :default_branch, @default_branch),
         :ok <- assigned_branch_allowed(assigned_branch, attrs),
         {:ok, allowed_paths} <- allowed_paths(attrs),
         {:ok, identity} <- optional_identity(attrs) do
      protected_branches = protected_branches(attrs)

      {:ok,
       %__MODULE__{
         repository: repository,
         worktree_path: worktree_path,
         base_branch: base_branch,
         assigned_branch: assigned_branch,
         default_branch: default_branch,
         workspace_id: identity.workspace_id,
         owner_ref: identity.owner_ref,
         runtime_id: identity.runtime_id,
         worker_id: identity.worker_id,
         release_sha: identity.release_sha,
         allowed_paths: allowed_paths,
         protected_branches: protected_branches,
         push_allowed?: truthy?(value(attrs, :push_allowed?, value(attrs, :allow_push, false)))
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_scope}

  @doc "Attach coordinator-owned identity after the worker process is created."
  @spec with_identity(t(), map()) :: {:ok, t()} | {:error, atom()}
  def with_identity(%__MODULE__{} = scope, attrs) when is_map(attrs) do
    attrs =
      Enum.into(
        [:workspace_id, :owner_ref, :runtime_id, :worker_id, :release_sha],
        %{},
        &{&1, value_or(attrs, &1, Map.get(scope, &1))}
      )

    with {:ok, identity} <- required_identity(attrs) do
      {:ok,
       %{
         scope
         | workspace_id: identity.workspace_id,
           owner_ref: identity.owner_ref,
           runtime_id: identity.runtime_id,
           worker_id: identity.worker_id,
           release_sha: identity.release_sha
       }}
    end
  end

  def with_identity(_scope, _attrs), do: {:error, :invalid_identity}

  @spec validate_paths(t(), term()) :: {:ok, [String.t()]} | {:error, atom()}
  def validate_paths(%__MODULE__{} = scope, paths) when is_list(paths) do
    paths = Enum.uniq(paths)

    cond do
      paths == [] ->
        {:error, :paths_required}

      length(paths) > @max_paths ->
        {:error, :too_many_paths}

      true ->
        paths
        |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
          case validate_path(scope, path) do
            :ok -> {:cont, {:ok, [path | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, paths} -> {:ok, Enum.reverse(paths)}
          other -> other
        end
    end
  end

  def validate_paths(_scope, _paths), do: {:error, :paths_required}

  @spec validate_path(t(), term()) :: :ok | {:error, atom()}
  def validate_path(%__MODULE__{} = scope, path) when is_binary(path) do
    cond do
      path == "" -> {:error, :invalid_path}
      byte_size(path) > @max_path_bytes -> {:error, :path_too_long}
      String.contains?(path, <<0>>) -> {:error, :nul_in_path}
      String.contains?(path, "\\") -> {:error, :backslash_in_path}
      Path.type(path) == :absolute -> {:error, :absolute_path}
      path in [".", ".."] -> {:error, :invalid_path}
      Enum.any?(Path.split(path), &(&1 in ["..", ".git"])) -> {:error, :path_not_allowed}
      PathSafety.ignored?(path) -> {:error, :path_not_allowed}
      path not in scope.allowed_paths -> {:error, :path_not_allowed}
      true -> :ok
    end
  end

  def validate_path(_scope, _path), do: {:error, :invalid_path}

  @spec validate_commit_message(term()) :: {:ok, String.t()} | {:error, atom()}
  def validate_commit_message(message) when is_binary(message) do
    message = String.trim(message)
    first_line = message |> String.split("\n", parts: 2) |> hd()

    cond do
      message == "" -> {:error, :commit_message_required}
      byte_size(message) > 4_096 -> {:error, :commit_message_too_large}
      byte_size(first_line) > 120 -> {:error, :commit_subject_too_long}
      String.contains?(message, <<0>>) -> {:error, :nul_in_commit_message}
      credential_material?(message) -> {:error, :credential_material}
      true -> {:ok, message}
    end
  end

  def validate_commit_message(_message), do: {:error, :commit_message_required}

  @spec public(t()) :: map()
  def public(%__MODULE__{} = scope) do
    %{
      repository: scope.repository,
      worktree_path: scope.worktree_path,
      base_branch: scope.base_branch,
      head_branch: scope.assigned_branch,
      workspace_id: scope.workspace_id,
      owner_ref: scope.owner_ref,
      runtime_id: scope.runtime_id,
      worker_id: scope.worker_id,
      release_sha: scope.release_sha,
      allowed_paths: scope.allowed_paths,
      push_allowed?: scope.push_allowed?
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp required_string(attrs, key) do
    case value(attrs, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing, key}}
          value -> {:ok, value}
        end

      _ ->
        {:error, {:missing, key}}
    end
  end

  defp safe_repository?(repository) do
    cond do
      String.contains?(repository, <<0>>) -> {:error, :nul_in_repository}
      credential_material?(repository) -> {:error, :credential_material}
      String.contains?(repository, "\n") -> {:error, :invalid_repository}
      true -> :ok
    end
  end

  defp required_path(attrs, key) do
    case required_string(attrs, key) do
      {:ok, path} ->
        expanded = Path.expand(path)

        if File.dir?(expanded) do
          {:ok, expanded}
        else
          {:error, :worktree_not_found}
        end

      other ->
        other
    end
  end

  defp branch(attrs, key, default) do
    case value(attrs, key, default) do
      nil when is_nil(default) ->
        {:error, {:missing, key}}

      branch when is_binary(branch) ->
        branch = String.trim(branch)

        if valid_branch?(branch), do: {:ok, branch}, else: {:error, :invalid_branch}

      _ ->
        {:error, :invalid_branch}
    end
  end

  defp branch_value(attrs, key, default) do
    case value(attrs, key, default) do
      branch when is_binary(branch) ->
        branch = String.trim(branch)
        if valid_branch?(branch), do: branch, else: default

      _ ->
        default
    end
  end

  defp assigned_branch_allowed(branch, attrs) do
    default = branch_value(attrs, :default_branch, @default_branch)

    protected =
      attrs
      |> value(:protected_branches, @protected_branches)
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)

    cond do
      branch == default -> {:error, :protected_branch}
      branch in protected -> {:error, :protected_branch}
      String.starts_with?(branch, "refs/") -> {:error, :protected_branch}
      true -> :ok
    end
  end

  defp allowed_paths(attrs) do
    paths = value(attrs, :allowed_paths, [])

    if is_list(paths) and Enum.all?(paths, &is_binary/1) do
      paths =
        paths
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      if length(paths) <= @max_paths and Enum.all?(paths, &allowlist_path?/1) do
        {:ok, paths}
      else
        {:error, :invalid_allowed_paths}
      end
    else
      {:error, :invalid_allowed_paths}
    end
  end

  defp protected_branches(attrs) do
    attrs
    |> value(:protected_branches, @protected_branches)
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp optional_identity(attrs) do
    with {:ok, owner_ref} <- optional_owner_ref(attrs) do
      values = %{
        workspace_id: optional_string(attrs, :workspace_id),
        owner_ref: owner_ref,
        runtime_id: optional_string(attrs, :runtime_id),
        worker_id: optional_string(attrs, :worker_id),
        release_sha: value(attrs, :release_sha)
      }

      cond do
        Enum.any?(
          [values.workspace_id, values.runtime_id, values.worker_id],
          &invalid_identity_value?/1
        ) ->
          {:error, :invalid_identity}

        Enum.any?(
          [values.workspace_id, values.runtime_id, values.worker_id],
          &invalid_scalar_id?/1
        ) ->
          {:error, :invalid_identity}

        not is_nil(values.release_sha) and not valid_sha?(values.release_sha) ->
          {:error, :invalid_release_sha}

        true ->
          {:ok, values}
      end
    end
  end

  defp required_identity(attrs) do
    with {:ok, owner_ref} <- required_owner_ref(attrs) do
      values = %{
        workspace_id: optional_string(attrs, :workspace_id),
        owner_ref: owner_ref,
        runtime_id: optional_string(attrs, :runtime_id),
        worker_id: optional_string(attrs, :worker_id),
        release_sha: value(attrs, :release_sha)
      }

      cond do
        Enum.any?(
          [values.workspace_id, values.owner_ref, values.runtime_id, values.worker_id],
          &is_nil/1
        ) ->
          {:error, :invalid_identity}

        Enum.any?(
          [values.workspace_id, values.runtime_id, values.worker_id],
          &invalid_identity_value?/1
        ) ->
          {:error, :invalid_identity}

        Enum.any?(
          [values.workspace_id, values.runtime_id, values.worker_id],
          &invalid_scalar_id?/1
        ) ->
          {:error, :invalid_identity}

        is_binary(values.release_sha) and not valid_sha?(values.release_sha) ->
          {:error, :invalid_release_sha}

        values.release_sha not in [nil, ""] and not is_binary(values.release_sha) ->
          {:error, :invalid_release_sha}

        true ->
          {:ok, values}
      end
    end
  end

  defp optional_owner_ref(attrs) do
    case value(attrs, :owner_ref) do
      nil ->
        {:ok, nil}

      value ->
        case OwnerRef.normalize(value) do
          {:ok, owner_ref} -> {:ok, owner_ref}
          {:error, _reason} -> {:error, :invalid_owner_ref}
        end
    end
  end

  defp required_owner_ref(attrs) do
    case value(attrs, :owner_ref) do
      nil ->
        {:error, :invalid_owner_ref}

      value ->
        case OwnerRef.normalize(value) do
          {:ok, owner_ref} -> {:ok, owner_ref}
          {:error, _reason} -> {:error, :invalid_owner_ref}
        end
    end
  end

  defp optional_string(attrs, key) do
    case value(attrs, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          value -> value
        end

      nil ->
        nil

      _ ->
        :invalid
    end
  end

  defp invalid_identity_value?(:invalid), do: true

  defp invalid_identity_value?(value) when is_binary(value),
    do:
      credential_material?(value) or String.contains?(value, <<0>>) or
        String.contains?(value, "\n") or byte_size(value) > 256

  defp invalid_identity_value?(nil), do: false
  defp invalid_identity_value?(_), do: true

  defp invalid_scalar_id?(nil), do: false
  defp invalid_scalar_id?(value), do: not Limits.valid_scalar_id?(value)

  defp valid_sha?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{40}\z/, value)

  defp allowlist_path?(path) do
    Path.type(path) != :absolute and
      not String.contains?(path, <<0>>) and
      not String.contains?(path, "\\") and
      Enum.all?(Path.split(path), &(&1 not in ["..", ".git"])) and
      not PathSafety.ignored?(path)
  end

  defp valid_branch?(branch) do
    branch != "" and
      byte_size(branch) <= 255 and
      not String.starts_with?(branch, "-") and
      not String.ends_with?(branch, ".") and
      not String.ends_with?(branch, "/") and
      not String.contains?(branch, "..") and
      not String.contains?(branch, "@{") and
      not String.contains?(branch, "\\") and
      not String.contains?(branch, " ") and
      not String.contains?(branch, "\t") and
      not String.contains?(branch, "\n")
  end

  defp credential_material?(value) when is_binary(value) do
    Regex.match?(
      ~r/(?:bearer\s+|password\s*=|token\s*=|api[_-]?key\s*=|gh[pousr]_|xox[baprs]-|-----begin .* private key)/i,
      value
    )
  end

  defp value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp value_or(attrs, key, fallback) do
    case value(attrs, key) do
      nil -> fallback
      value -> value
    end
  end

  defp truthy?(value), do: value in [true, "true", "1", 1]
end
