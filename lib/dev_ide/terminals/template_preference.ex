defmodule DevIDE.Terminals.TemplatePreference do
  @moduledoc """
  Remembers the last session template applied per workspace so a tmux server
  wipe can re-apply operator/agent layout (e.g. `agent_pair`) automatically.
  """

  @table :dev_ide_template_preferences

  def ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        access = Application.get_env(:dev_ide, :ets_table_access, :protected)
        :ets.new(@table, [:named_table, access, :set])
        :ok

      _ ->
        :ok
    end
  end

  @doc "Record that `template_id` was applied for `workspace_id`."
  @spec put(String.t(), String.t()) :: :ok
  def put(workspace_id, template_id)
      when is_binary(workspace_id) and is_binary(template_id) and template_id != "" do
    ensure_table!()
    true = :ets.insert(@table, {workspace_id, template_id, System.system_time(:second)})
    _ = maybe_write_disk(workspace_id, template_id)
    :ok
  rescue
    _ -> :ok
  end

  def put(_, _), do: :ok

  @doc "Last template id for `workspace_id`, or nil."
  @spec get(String.t()) :: String.t() | nil
  def get(workspace_id) when is_binary(workspace_id) do
    ensure_table!()

    case :ets.lookup(@table, workspace_id) do
      [{^workspace_id, template_id, _}] when is_binary(template_id) ->
        template_id

      _ ->
        case read_disk(workspace_id) do
          {:ok, template_id} ->
            true = :ets.insert(@table, {workspace_id, template_id, System.system_time(:second)})
            template_id

          _ ->
            nil
        end
    end
  rescue
    _ -> nil
  end

  def get(_), do: nil

  @doc "Fallback template when none was recorded (agent workflows)."
  def default_recovery_template, do: "agent_pair"

  defp store_dir do
    Application.get_env(:dev_ide, :tmux_template_preference_dir) ||
      Path.join(System.tmp_dir!(), "devide-template-prefs")
  end

  defp disk_path(workspace_id) do
    safe = String.replace(workspace_id, ~r/[^A-Za-z0-9._-]+/, "_")
    Path.join(store_dir(), safe <> ".template")
  end

  defp maybe_write_disk(workspace_id, template_id) do
    File.mkdir_p!(store_dir())
    File.write!(disk_path(workspace_id), template_id)
  end

  defp read_disk(workspace_id) do
    case File.read(disk_path(workspace_id)) do
      {:ok, id} ->
        id = String.trim(id)
        if id == "", do: :error, else: {:ok, id}

      error ->
        error
    end
  end
end
