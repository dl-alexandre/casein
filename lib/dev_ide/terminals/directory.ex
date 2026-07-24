defmodule DevIDE.Terminals.Directory do
  @moduledoc false

  alias DevIDE.Terminals.{SessionDirectory, SessionRegistry}
  alias DevIDE.Terminals.Session.Info
  alias DevIDE.Terminals.SessionDirectory.Compose

  defdelegate new_shell(workspace_id, sid, opts \\ []), to: Info
  defdelegate new_agent(agent_id, opts \\ []), to: Info

  @doc "Lists all attachable terminal sessions for a workspace."
  @spec list_attachable(String.t()) :: [Info.t()]
  def list_attachable(workspace_id) do
    SessionRegistry.list_attachable(workspace_id)
  end

  @doc """
  Canonical session tab list for a workspace (live shells + scanned tmux
  sessions, deduplicated). Served by the per-workspace `SessionDirectory`;
  viewer-independent — apply `visible_tabs/2`.
  """
  @spec session_tabs(String.t(), keyword()) :: [Info.t()]
  defdelegate session_tabs(workspace_id, opts \\ []), to: SessionDirectory, as: :tabs

  @doc "Subscribes the caller to `{:sessions_updated, workspace_id, tabs}` broadcasts."
  @spec subscribe_session_tabs(String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate subscribe_session_tabs(workspace_id, opts \\ []),
    to: SessionDirectory,
    as: :subscribe

  @doc "Drops the caller's session-tab PubSub subscription and directory watch."
  @spec unsubscribe_session_tabs(String.t(), pid()) :: :ok
  defdelegate unsubscribe_session_tabs(workspace_id, watcher_pid \\ self()),
    to: SessionDirectory,
    as: :unsubscribe

  @doc "Applies the per-viewer staleness/default-shell filters to a tab list."
  @spec visible_tabs([Info.t()], String.t() | nil) :: [Info.t()]
  defdelegate visible_tabs(tabs, default_sid), to: Compose, as: :visible_for

  @doc "Returns the workspace shell family prefix for a terminal session id."
  @spec shell_family(String.t() | nil) :: String.t() | nil
  defdelegate shell_family(sid), to: Compose

  @doc "Ensures the viewer's landing session is present so the picker always shows a home row."
  @spec with_default_shell([Info.t()], String.t() | nil, String.t(), String.t()) :: [Info.t()]
  defdelegate with_default_shell(tabs, default_sid, workspace_id, workspace_name), to: Compose

  @doc "Resolves a session identifier into session information."
  @spec resolve(String.t()) :: {:ok, Info.t()} | :error
  def resolve(sid) do
    SessionRegistry.resolve(sid)
  end

  @doc "True when the resolved session info is for an interactive shell."
  @spec shell_session?(Info.t() | term()) :: boolean()
  def shell_session?(%Info{kind: :shell}), do: true
  def shell_session?(_), do: false

  @doc "True when the term is a terminal session info struct."
  @spec session_info?(term()) :: boolean()
  def session_info?(%Info{}), do: true
  def session_info?(_), do: false

  @doc "Prepares attachment data for a given session id."
  @spec prepare_attachment(String.t()) :: {:ok, Info.t()} | :error
  def prepare_attachment(sid) do
    resolve(sid)
  end

  @doc "Fetches one canonical session tab for a workspace."
  @spec fetch_session_tab(String.t(), String.t(), keyword()) :: {:ok, Info.t()} | :error
  def fetch_session_tab(workspace_id, sid, opts \\ []) do
    SessionDirectory.fetch(workspace_id, sid, opts)
  end

  @doc "Reads cached canonical session tabs for a workspace."
  @spec read_session_tabs(String.t(), keyword()) :: [Info.t()]
  def read_session_tabs(workspace_id, opts \\ []) do
    SessionDirectory.read(workspace_id, opts)
  end

  @doc "Forces a canonical session tab refresh for a workspace."
  @spec refresh_session_tabs_now(String.t(), keyword()) :: [Info.t()]
  def refresh_session_tabs_now(workspace_id, opts \\ []) do
    SessionDirectory.refresh_now(workspace_id, opts)
  end

  @doc "Module tag used by session directory PubSub broadcasts."
  @spec session_tabs_event_source() :: module()
  def session_tabs_event_source, do: SessionDirectory

  @doc "True when a PubSub source is the session tabs broadcaster."
  @spec session_tabs_event_source?(module()) :: boolean()
  def session_tabs_event_source?(source), do: source == SessionDirectory
end
