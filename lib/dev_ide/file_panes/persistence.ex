defmodule DevIDE.FilePanes.Persistence do
  @moduledoc """
  Pure Repo persistence for file-pane registrations. No process state; every
  function runs inside a caller-supplied offload task (under that task's
  `$callers`/Ecto sandbox ownership — see `DevIDE.FilePanes` I6). All Repo access
  is rescue-guarded so a DB error degrades to a benign result instead of crashing
  the offload task.
  """

  import Ecto.Query

  alias DevIDE.FilePanes.FilePaneRegistration
  alias DevIDE.Repo

  def enabled? do
    Application.get_env(:dev_ide, :file_pane_persistence, true)
  end

  def upsert(reg) do
    if enabled?() do
      attrs = %{
        workspace_id: reg.workspace_id,
        tmux_session: reg.tmux_session,
        pane_id: reg.pane_id,
        pane_window_id: reg.pane_window_id,
        placement: reg.placement,
        anchor_pane_id: reg.anchor_pane_id,
        anchor_window_id: reg.anchor_window_id,
        open_files: Enum.map(reg.open_files, &%{"path" => &1.path, "line" => &1.line}),
        active_path: reg.active_path,
        status: :open
      }

      # Partial unique index file_pane_registrations_open_pane_id_index
      # (pane_id WHERE status = 'open') — single round-trip upsert.
      case %FilePaneRegistration{}
           |> FilePaneRegistration.changeset(attrs)
           |> Repo.insert(
             on_conflict:
               {:replace,
                [
                  :workspace_id,
                  :tmux_session,
                  :pane_window_id,
                  :placement,
                  :anchor_pane_id,
                  :anchor_window_id,
                  :open_files,
                  :active_path,
                  :status,
                  :updated_at
                ]},
             conflict_target: {:unsafe_fragment, "(pane_id) WHERE (status = 'open')"}
           ) do
        {:ok, row} -> {:ok, row}
        {:error, _} = err -> err
      end
    else
      {:ok, reg}
    end
  rescue
    _ -> {:ok, reg}
  end

  def close(pane_id) when is_binary(pane_id), do: close_many([pane_id])

  def close_many(pane_ids) when is_list(pane_ids) do
    pane_ids =
      pane_ids
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    if pane_ids != [] and enabled?() do
      from(r in FilePaneRegistration, where: r.pane_id in ^pane_ids and r.status == :open)
      |> Repo.update_all(set: [status: :closed])
    end

    :ok
  rescue
    _ -> :ok
  end

  def close_all do
    if enabled?() do
      from(r in FilePaneRegistration, where: r.status == :open)
      |> Repo.update_all(set: [status: :closed])
    end

    :ok
  rescue
    _ -> :ok
  end

  def load_open(pane_id) do
    if enabled?() do
      Repo.one(
        from(r in FilePaneRegistration,
          where: r.pane_id == ^pane_id and r.status == :open,
          limit: 1
        )
      )
    end
  rescue
    _ -> nil
  end

  def load_open_for_workspaces(workspace_ids) do
    ids = Enum.reject(workspace_ids, &(&1 in [nil, ""]))

    if ids == [] or not enabled?() do
      []
    else
      Repo.all(
        from(r in FilePaneRegistration,
          where: r.workspace_id in ^ids and r.status == :open,
          order_by: [asc: r.inserted_at]
        )
      )
    end
  rescue
    _ -> []
  end
end
