defmodule DevIDE.Links.Open do
  @moduledoc """
  PubSub and JSON helpers for workspace open-target requests.

  `/api/workspaces/:id/open` resolves targets once at the API boundary, echoes
  the typed result to the caller, then broadcasts the same typed target to all
  connected workspace viewers.
  """

  @type resolved_target :: DevIDE.Links.Resolver.target()

  @spec topic(String.t()) :: String.t()
  def topic(workspace_id) when is_binary(workspace_id), do: "links:" <> workspace_id

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(workspace_id) when is_binary(workspace_id) do
    Phoenix.PubSub.subscribe(DevIDE.PubSub, topic(workspace_id))
  end

  @spec broadcast(String.t(), resolved_target()) :: :ok | {:error, term()}
  def broadcast(workspace_id, resolved) when is_binary(workspace_id) do
    Phoenix.PubSub.broadcast(DevIDE.PubSub, topic(workspace_id), {:open_target, resolved})
  end

  @spec to_json(resolved_target()) :: map()
  def to_json({:file, %{path: path, line: line, col: col}}) do
    %{kind: "file", path: path, line: line, col: col}
  end

  def to_json({:markdown, %{path: path, anchor: anchor}}) do
    %{kind: "markdown", path: path, anchor: anchor}
  end

  def to_json({:dir, path}) do
    %{kind: "dir", path: path}
  end

  def to_json({:localhost, %{url: url, port: port}}) do
    %{kind: "localhost", url: url, port: port}
  end

  def to_json({:external, %{url: url}}) do
    %{kind: "external", url: url}
  end
end
