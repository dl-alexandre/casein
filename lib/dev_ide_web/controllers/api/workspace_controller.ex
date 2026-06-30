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

  def previous_sessions(conn, %{"id" => id}) do
    case Export.previous_sessions(id, previous_sessions_opts(conn)) do
      {:ok, payload} -> json(conn, json_value(payload))
      :error -> not_found(conn)
    end
  end

  defp previous_sessions_opts(conn) do
    []
    |> maybe_put_opt(:query, param(conn, "query") || param(conn, "q"))
    |> maybe_put_opt(
      :workspace,
      param(conn, "workspace") || param(conn, "workspace_id") || param(conn, "workspace_name")
    )
    |> maybe_put_opt(:source, param(conn, "source") || param(conn, "sources"))
    |> maybe_put_opt(:session, param(conn, "session") || param(conn, "session_id"))
    |> maybe_put_opt(:pane, param(conn, "pane") || param(conn, "pane_id"))
    |> maybe_put_opt(:since, param(conn, "since") || param(conn, "from"))
    |> maybe_put_opt(:until, param(conn, "until") || param(conn, "to"))
    |> maybe_put_opt(:limit, int_param(conn.params, "limit"))
    |> maybe_put_opt(:source_limit, int_param(conn.params, "source_limit"))
  end

  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_value(%Date{} = value), do: Date.to_iso8601(value)
  defp json_value(%Time{} = value), do: Time.to_iso8601(value)

  defp json_value(value) when is_map(value) do
    Map.new(value, fn {key, child} -> {json_key(key), json_value(child)} end)
  end

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value) when value in [nil, true, false], do: value
  defp json_value(value) when is_binary(value), do: value
  defp json_value(value) when is_number(value), do: value
  defp json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_value(value), do: inspect(value, limit: 20, printable_limit: 200)

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key), do: inspect(key, limit: 20, printable_limit: 200)
end
