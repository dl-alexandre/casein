defmodule Casein.Terminals.Telemetry do
  @moduledoc """
  Terminal-specific telemetry counters maintained with O(1) ETS reads.

  Gauges are updated on owner/attachment lifecycle events instead of polling
  owner process state through Registry + :sys.get_state.
  """

  require Logger

  @table_name :casein_terminal_metrics

  @doc "Initializes the metrics table when used."
  def ensure_table! do
    case :ets.whereis(@table_name) do
      :undefined ->
        :ets.new(@table_name, [:named_table, :public, :set])

      _ ->
        :ok
    end

    :ok
  end

  @doc "Count of currently active SessionOwner processes."
  def count_active_owners do
    ensure_table!()

    case :ets.lookup(@table_name, :active_owners) do
      [{:active_owners, count}] -> count
      _ -> 0
    end
  end

  @doc "Count of owners with an open attachment."
  def count_open_attachments do
    ensure_table!()

    case :ets.lookup(@table_name, :open_attachments) do
      [{:open_attachments, count}] -> count
      _ -> 0
    end
  end

  @doc "Pids of live `:shell` SessionOwner processes."
  def shell_owner_pids do
    ensure_table!()

    :ets.tab2list(@table_name)
    |> Enum.flat_map(fn
      {{:owner_key, pid}, {:terminal_owner, :shell, _, _}} when is_pid(pid) ->
        if Process.alive?(pid), do: [pid], else: []

      _ ->
        []
    end)
  end

  @doc "Returns a list of {owner_key, subscriber_count} for active owners."
  def subscribers_per_owner do
    ensure_table!()

    :ets.select(@table_name, [
      {
        {{:owner_subscribers, :"$1"}, :"$2", :"$3"},
        [],
        [
          {{:"$3", :"$2"}}
        ]
      }
    ])
  end

  @doc "Attach to telemetry poller by returning the measurement spec list."
  def periodic_measurements do
    [
      {__MODULE__, :emit_owner_counts, []}
    ]
  end

  def emit_owner_counts do
    active = count_active_owners()
    open_att = count_open_attachments()

    :telemetry.execute([:casein, :terminals, :owners, :active], %{count: active}, %{})
    :telemetry.execute([:casein, :terminals, :attachments, :open], %{count: open_att}, %{})

    if rem(System.unique_integer([:positive]), 20) == 0 do
      Logger.debug("terminals telemetry snapshot",
        active_owners: active,
        open_attachments: open_att
      )
    end
  rescue
    e -> Logger.debug("telemetry poller skipped: #{Exception.message(e)}")
  end

  @doc "Registers a new owner process and initial stats entries."
  def owner_started(pid, kind, owner_key) when is_pid(pid) do
    ensure_table!()

    :ets.update_counter(@table_name, :active_owners, {2, 1}, {:active_owners, 0})
    :ets.insert(@table_name, {{:owner_key, pid}, owner_key})
    :ets.insert(@table_name, {{:owner_subscribers, pid}, 0, owner_key})

    :telemetry.execute([:casein, :terminals, :owner, :started], %{count: 1}, %{kind: kind})
    :ok
  end

  @doc "Updates current owner subscriber count."
  def set_owner_subscribers(pid, count) when is_pid(pid) and is_integer(count) do
    ensure_table!()

    key = owner_key_of(pid)
    normalized = max(count, 0)

    :ets.insert(@table_name, {{:owner_subscribers, pid}, normalized, key})
    :ok
  end

  @doc "Tracks owner teardown and clears per-owner counters."
  def owner_stopped(pid) when is_pid(pid) do
    ensure_table!()

    :ets.update_counter(@table_name, :active_owners, {2, -1}, {:active_owners, 0})
    :ets.delete(@table_name, {:owner_key, pid})
    :ets.delete(@table_name, {:owner_subscribers, pid})
    :ok
  end

  @doc "Open attachment count increment."
  def owner_attachment_opened do
    ensure_table!()
    :ets.update_counter(@table_name, :open_attachments, {2, 1}, {:open_attachments, 0})
    :ok
  end

  @doc "Open attachment count decrement."
  def owner_attachment_closed do
    ensure_table!()

    case :ets.lookup(@table_name, :open_attachments) do
      [{:open_attachments, count}] when count > 0 ->
        :ets.update_counter(@table_name, :open_attachments, {2, -1}, {:open_attachments, 0})

      _ ->
        :ok
    end
  end

  defp owner_key_of(pid) do
    case :ets.lookup(@table_name, {:owner_key, pid}) do
      [{_, key}] -> key
      _ -> nil
    end
  end
end
