defmodule Casein.Workspaces.Identity do
  @moduledoc """
  Single workspace-identity resolver for terminal MCP tools.

  Resolves a caller-supplied `workspace_id` — manager UUID, workspace
  name/slug, or `folder:` id — against the local `State` cache only.
  Never blocks on `Workspaces.get/1` (manager HTTP). Every tool that
  scopes tmux sessions must go through this module so list and
  mutate agree on the same `(workspace_id, session)` pair.
  """

  alias Casein.Terminals.Tmux
  alias Casein.Terminals.TmuxPolicy
  alias Casein.Workspaces
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.WorkspaceRecord

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @type kind :: :uuid | :slug | :folder

  @type t :: %{
          arg: String.t(),
          kind: kind(),
          id: String.t() | nil,
          name: String.t() | nil,
          aliases: [String.t()],
          prefixes: [String.t()]
        }

  @doc "Classify a workspace_id argument without resolving it."
  @spec kind(term()) :: kind() | :missing
  def kind("folder:" <> _), do: :folder

  def kind(id) when is_binary(id) do
    if uuid?(id), do: :uuid, else: :slug
  end

  def kind(_), do: :missing

  @doc """
  Resolve a workspace_id to its local identity.

  Always succeeds for a non-empty binary: an unknown id is still a
  namespace candidate (the raw argument), so slug-prefixed sessions
  match without a manager round trip. Empty/nil is `{:error, :missing_workspace_id}`.
  """
  @spec resolve(term()) :: {:ok, t()} | {:error, :missing_workspace_id}
  def resolve(id) when is_binary(id) do
    case String.trim(id) do
      "" ->
        {:error, :missing_workspace_id}

      trimmed ->
        {:ok, identity_for(trimmed)}
    end
  end

  def resolve(_), do: {:error, :missing_workspace_id}

  @doc "Tmux session prefixes allowed for this workspace_id."
  @spec prefixes(term()) :: [String.t()]
  def prefixes(id) do
    case resolve(id) do
      {:ok, identity} -> identity.prefixes
      {:error, _} -> []
    end
  end

  @doc "True when `session` belongs to the resolved workspace namespace."
  @spec session_in_workspace?(term(), term()) :: boolean()
  def session_in_workspace?(session, workspace_id)
      when is_binary(session) and session != "" do
    workspace_id
    |> prefixes()
    |> Enum.any?(&TmuxPolicy.session_in_namespace?(session, &1))
  end

  def session_in_workspace?(_session, _workspace_id), do: false

  @doc """
  Workspace name segment of a Casein tmux session (`casein_<ws>_<sid>`).

  The sid is the last underscore-free segment by construction.
  """
  @spec session_workspace(term()) :: String.t() | nil
  def session_workspace("casein_" <> rest) when rest != "" do
    case String.split(rest, "_") do
      [] ->
        nil

      parts ->
        case Enum.split(parts, -1) do
          {ws_parts, [_sid]} when ws_parts != [] -> Enum.join(ws_parts, "_")
          _ -> nil
        end
    end
  end

  def session_workspace(_), do: nil

  @doc """
  Structured `workspace_mismatch` naming both resolved identities.

  `workspace` is what the caller argument resolved to; `session` is what
  the tmux session name resolved to.
  """
  @spec mismatch(term(), term()) :: map()
  def mismatch(workspace_arg, session) do
    workspace =
      case resolve(workspace_arg) do
        {:ok, identity} -> identity
        {:error, :missing_workspace_id} -> missing_identity(workspace_arg)
      end

    %{
      error: :workspace_mismatch,
      workspace: workspace,
      session: session_identity(session)
    }
  end

  defp identity_for(id) do
    case record_for(id) do
      %WorkspaceRecord{} = record -> from_record(id, record)
      _ -> from_raw(id)
    end
  end

  defp record_for(id) do
    case State.get(id) do
      {:ok, record} -> record
      :error -> record_by_name(id) || record_by_folder(id)
    end
  end

  defp record_by_name(id) do
    sanitized = TmuxPolicy.sanitize(id)

    Enum.find(State.list(), fn record ->
      name = record.name || ""
      name == id or record.external_id == id or TmuxPolicy.sanitize(name) == sanitized
    end)
  end

  defp record_by_folder(id) do
    case Workspaces.decode_folder_id(id) do
      path when is_binary(path) ->
        expanded = Path.expand(path)

        case State.records_for_host_paths([expanded]) do
          %{^expanded => record} -> record
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp from_record(arg, %WorkspaceRecord{} = record) do
    aliases =
      [record.external_id, record.name, arg]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    %{
      arg: arg,
      kind: kind(arg),
      id: record.external_id,
      name: record.name,
      aliases: aliases,
      prefixes: prefixes_for(aliases)
    }
  end

  defp from_raw(arg) do
    %{
      arg: arg,
      kind: kind(arg),
      id: arg,
      name: nil,
      aliases: [arg],
      prefixes: prefixes_for([arg])
    }
  end

  defp missing_identity(arg) do
    %{
      arg: arg,
      kind: :missing,
      id: nil,
      name: nil,
      aliases: [],
      prefixes: []
    }
  end

  defp session_identity(session) when is_binary(session) do
    ws = session_workspace(session)
    aliases = Enum.filter([ws], &(is_binary(&1) and &1 != ""))

    %{
      name: session,
      workspace: ws,
      aliases: aliases,
      prefixes: prefixes_for(aliases)
    }
  end

  defp session_identity(session) do
    %{name: session, workspace: nil, aliases: [], prefixes: []}
  end

  defp prefixes_for(candidates) do
    candidates
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&Tmux.workspace_session_prefix/1)
    |> Enum.uniq()
  end

  defp uuid?(id), do: Regex.match?(@uuid, id)
end
