defmodule DevIDE.Workspaces.SessionSummary do
  @moduledoc """
  Compact cross-workspace summary for switchers and pickers.

  This is intentionally a read model: it combines manager workspace data with
  live-but-cheap local observations (tmux sessions, runtimes, git status) and
  returns presentation-ready maps. Mutating terminal/session behavior remains
  in the workspace cockpit.
  """

  alias DevIDE.Git
  alias DevIDE.Runtimes
  alias DevIDE.Terminals.SessionDirectory

  @type summary :: %{
          id: String.t(),
          name: String.t(),
          user: String.t() | nil,
          branch: String.t() | nil,
          status: atom() | String.t() | nil,
          host_id: String.t(),
          path: String.t() | nil,
          path_label: String.t() | nil,
          dirty_count: non_neg_integer() | nil,
          session_count: non_neg_integer(),
          sessions: [map()],
          runtime_count: non_neg_integer(),
          active_runtime_count: non_neg_integer()
        }

  @spec build(map()) :: summary()
  def build(ws) when is_map(ws) do
    id = workspace_id(ws)
    name = workspace_name(ws)
    path = Map.get(ws, :path) || Map.get(ws, :host_path)
    sessions = sessions(ws)
    runtimes = Runtimes.list_runtimes(%{"workspace_id" => id})

    %{
      id: id,
      name: name,
      user: workspace_user(ws),
      branch: branch(ws, path),
      status: Map.get(ws, :status) || Map.get(ws, :mode),
      host_id: Map.get(ws, :host_id) || Map.get(ws, :host) || "local",
      path: path,
      path_label: path_label(path),
      dirty_count: dirty_count(path),
      session_count: length(sessions),
      sessions: Enum.map(sessions, &session_link(ws, &1)),
      runtime_count: length(runtimes),
      active_runtime_count: Enum.count(runtimes, &active_runtime?/1)
    }
  end

  @spec build_many([map()]) :: [summary()]
  def build_many(workspaces) when is_list(workspaces), do: Enum.map(workspaces, &build/1)

  @spec path_label(String.t() | nil) :: String.t() | nil
  def path_label(path) when is_binary(path) and path != "" do
    parts = String.split(path, "/", trim: true)

    case parts do
      [] -> path
      [only] -> only
      _ -> Enum.take(parts, -2) |> Enum.join("/")
    end
  end

  def path_label(_), do: nil

  defp branch(ws, path) do
    Map.get(ws, :branch) || metadata_value(ws, "branch") || git_branch(path)
  end

  defp git_branch(path) when is_binary(path) and path != "" do
    case Git.branch(path) do
      {:ok, branch} when branch != "" -> branch
      _ -> nil
    end
  end

  defp git_branch(_), do: nil

  defp dirty_count(path) when is_binary(path) and path != "" do
    case Git.status_short(path) do
      {:ok, entries} -> length(entries)
      _ -> nil
    end
  end

  defp dirty_count(_), do: nil

  defp sessions(ws) do
    id = workspace_id(ws)
    name = workspace_name(ws)

    SessionDirectory.read(id, workspace_name: name || id)
  end

  defp session_link(ws, session) do
    id = session_id(session)
    ws_id = workspace_id(ws)

    %{
      id: id,
      kind: session.kind,
      label: session_label(session.kind),
      href:
        "/workspaces/#{ws_id}?" <>
          URI.encode_query(%{
            "host" => Map.get(ws, :host_id) || Map.get(ws, :host) || "local",
            "session" => id
          }),
      tmux_session: session.tmux_session
    }
  end

  defp workspace_id(ws), do: Map.get(ws, :id) || Map.get(ws, :external_id)
  defp workspace_name(ws), do: Map.get(ws, :name) || workspace_id(ws)

  defp workspace_user(ws) do
    Map.get(ws, :user) || metadata_value(ws, "user")
  end

  defp metadata_value(ws, key) do
    metadata = Map.get(ws, :metadata) || Map.get(ws, :manager_payload) || %{}

    Map.get(metadata, key) ||
      get_in(metadata, ["raw", key]) ||
      get_in(metadata, [:raw, key])
  end

  defp session_id(%{kind: :shell, sid: sid}), do: sid
  defp session_id(%{id: id}), do: id

  defp session_label(:shell), do: "Shell"
  defp session_label(:execution), do: "Exec"
  defp session_label(:agent), do: "Agent"
  defp session_label(kind) when is_atom(kind), do: kind |> Atom.to_string() |> String.capitalize()
  defp session_label(kind), do: to_string(kind)

  defp active_runtime?(%{status: status}) when status in ["active", "bound", "provisioned"],
    do: true

  defp active_runtime?(_runtime), do: false
end
