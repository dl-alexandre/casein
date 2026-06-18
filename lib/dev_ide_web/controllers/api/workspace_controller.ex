defmodule DevIdeWeb.API.WorkspaceController do
  @moduledoc """
  Core workspace API: listing, status, topology snapshot, run history,
  proposals, and audit export.

  Window, pane, and template endpoints live in their own controllers
  (`WorkspaceWindowController`, `WorkspacePaneController`,
  `WorkspaceTemplateController`) and share helpers via
  `DevIdeWeb.API.WorkspaceAPI`.
  """

  use DevIdeWeb, :controller

  import DevIdeWeb.API.WorkspaceAPI

  alias DevIDE.Export

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
end
