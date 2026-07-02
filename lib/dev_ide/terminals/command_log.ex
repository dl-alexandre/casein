defmodule DevIDE.Terminals.CommandLog do
  @moduledoc """
  Bounded ETS command log for shell-integration records.

  Records are keyed by `{workspace_id, sid, pane_id_or_session}`. The table is
  public because `SessionOwner` processes write from outside the application
  root process that creates the table; only trusted app code runs in this BEAM.
  """

  alias DevIDE.Terminals.PaneCommand

  @table :dev_ide_terminal_command_log
  @default_limit 200

  @spec ensure_table!() :: :ok
  def ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  @spec append(PaneCommand.t()) :: :ok
  def append(%PaneCommand{workspace_id: workspace_id, sid: sid} = command)
      when is_binary(workspace_id) and is_binary(sid) do
    ensure_table!()
    key = key(workspace_id, sid, command.pane_id)
    existing = lookup_key(key)

    next =
      [command | existing]
      |> Enum.uniq_by(& &1.id)
      |> Enum.take(limit())

    :ets.insert(@table, {key, next})
    :ok
  end

  def append(%PaneCommand{}), do: :ok

  @spec list(String.t(), String.t(), keyword()) :: [PaneCommand.t()]
  def list(workspace_id, sid, opts \\ []) when is_binary(workspace_id) and is_binary(sid) do
    ensure_table!()

    pane_id = Keyword.get(opts, :pane_id)
    since_seq = Keyword.get(opts, :since_seq)
    last_n = opts |> Keyword.get(:last_n, 20) |> clamp_last_n()

    workspace_id
    |> records_for(sid, pane_id)
    |> Enum.filter(&after_seq?(&1, since_seq))
    |> Enum.sort_by(& &1.seq, :desc)
    |> Enum.take(last_n)
  end

  @spec reset!() :: :ok
  def reset! do
    ensure_table!()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp records_for(workspace_id, sid, nil) do
    match = {{{workspace_id, sid, :_}, :"$1"}, [], [:"$1"]}

    @table
    |> :ets.select([match])
    |> List.flatten()
  end

  defp records_for(workspace_id, sid, pane_id), do: lookup_key(key(workspace_id, sid, pane_id))

  defp lookup_key(key) do
    case :ets.lookup(@table, key) do
      [{^key, records}] -> records
      _ -> []
    end
  end

  defp key(workspace_id, sid, pane_id), do: {workspace_id, sid, pane_id || :session}

  defp after_seq?(_command, nil), do: true

  defp after_seq?(%PaneCommand{seq: seq}, since_seq) when is_integer(since_seq),
    do: seq > since_seq

  defp after_seq?(_command, _since_seq), do: true

  defp clamp_last_n(n) when is_integer(n) and n > 0, do: min(n, limit())
  defp clamp_last_n(_n), do: 20

  defp limit do
    Application.get_env(:dev_ide, :terminal_command_log_limit, @default_limit)
  end
end
