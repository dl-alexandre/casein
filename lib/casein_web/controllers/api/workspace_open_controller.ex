defmodule CaseinWeb.API.WorkspaceOpenController do
  @moduledoc """
  Agent/API endpoint for opening resolver-verified workspace targets in all
  connected Casein viewers.
  """

  use CaseinWeb, :controller

  import CaseinWeb.API.WorkspaceAPI

  alias Casein.Links.Open
  alias Casein.Links.Resolver
  alias Casein.Links.Resolver.Ctx
  alias Casein.Workspace
  alias Casein.Workspaces

  def open(conn, %{"id" => workspace_id}) do
    with {:ok, target} <- required_trimmed_param(conn, "target", :target_required),
         {:ok, workspace} <- workspace_for_open(workspace_id) do
      ctx = %Ctx{
        workspace: workspace,
        base_dir: optional_base_dir(conn),
        source: :api
      }

      case Resolver.resolve(target, ctx) do
        {:ok, resolved} ->
          _ = Open.broadcast(workspace_id, resolved)
          json(conn, Open.to_json(resolved))

        :skip ->
          not_found(conn)

        {:error, reason} ->
          rejected(conn, :unprocessable_entity, reason)
      end
    else
      {:error, :target_required} -> rejected(conn, :unprocessable_entity, :target_required)
      {:error, _reason} -> not_found(conn)
    end
  end

  defp workspace_for_open(workspace_id) do
    case Workspaces.get(workspace_id) do
      {:ok, workspace} ->
        {:ok, workspace}

      _ ->
        workspace_from_record(workspace_id)
    end
  end

  defp workspace_from_record(workspace_id) do
    case Workspaces.get_record(workspace_id) do
      {:ok, record} ->
        {:ok,
         %Workspace{
           id: record.external_id,
           name: record.name,
           path: record.host_path,
           status: record_status(record.status),
           metadata: record.manager_payload || %{}
         }}

      :error ->
        {:error, :not_found}
    end
  end

  defp record_status(nil), do: :unknown

  defp record_status(status) when is_binary(status) do
    case status do
      "creating" -> :creating
      "queued" -> :queued
      "starting" -> :starting
      "running" -> :running
      "stopped" -> :stopped
      "deleting" -> :deleting
      "error" -> :error
      _ -> :unknown
    end
  end

  defp optional_base_dir(conn) do
    case param(conn, "base_dir") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
