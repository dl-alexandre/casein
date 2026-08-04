defmodule DevideMob.Outbox do
  @moduledoc """
  Durable queue for agent instructions typed while the phone is offline.

  A companion app is used in exactly the places connectivity is worst — a train,
  a lift, a basement. Without this, typing an instruction on a dropped channel
  lost the text and told the user to try again later, which is the one thing a
  phone client should never do.

  Entries are persisted through `DevideMob.SessionConfig` (`Mob.State`, DETS on
  device), so a queued instruction survives navigation, a screen crash, and an
  app restart. Each entry carries a `request_id` that the server uses to
  de-duplicate: a retry after an ambiguous failure replays the recorded outcome
  instead of pasting the same prompt into the agent pane twice.

  `DevideMob.SessionClient` owns the lifecycle — it enqueues on a failed send
  and flushes on rejoin.
  """

  alias DevideMob.SessionConfig

  @max_entries 20
  @max_attempts 5

  @type entry :: %{
          request_id: String.t(),
          workspace_id: String.t(),
          text: String.t(),
          submit: boolean(),
          queued_at: integer(),
          attempts: non_neg_integer()
        }

  @doc "Every queued entry, oldest first."
  @spec list() :: [entry()]
  def list, do: SessionConfig.outbox()

  @doc "Queued entries for one workspace."
  @spec list(String.t()) :: [entry()]
  def list(workspace_id) when is_binary(workspace_id) do
    Enum.filter(list(), &(&1.workspace_id == workspace_id))
  end

  @doc "How many instructions are waiting to go out for a workspace."
  @spec count(String.t()) :: non_neg_integer()
  def count(workspace_id) when is_binary(workspace_id), do: workspace_id |> list() |> length()

  @doc """
  Append an instruction to the queue and return the stored entry.

  The queue is capped: past `#{@max_entries}` entries the oldest is dropped. A
  phone that has been offline for hours should send the last thing you asked
  for, not replay a morning's worth of stale instructions.
  """
  @spec enqueue(String.t(), String.t(), keyword()) :: entry()
  def enqueue(workspace_id, text, opts \\ []) when is_binary(workspace_id) and is_binary(text) do
    entry = %{
      request_id: Keyword.get_lazy(opts, :request_id, &new_request_id/0),
      workspace_id: workspace_id,
      text: text,
      submit: Keyword.get(opts, :submit, true),
      queued_at: Keyword.get(opts, :now, System.os_time(:second)),
      attempts: 0
    }

    entries = (list() ++ [entry]) |> Enum.take(-@max_entries)
    SessionConfig.put_outbox(entries)
    entry
  end

  @doc "Drop an entry once the server has accepted it."
  @spec ack(String.t()) :: :ok
  def ack(request_id) when is_binary(request_id) do
    SessionConfig.put_outbox(Enum.reject(list(), &(&1.request_id == request_id)))
  end

  @doc """
  Record a failed attempt. An entry that has failed `#{@max_attempts}` times is
  dropped and returned as `{:dropped, entry}` so the caller can tell the user it
  gave up, rather than retrying forever against a workspace whose agent pane is
  gone.
  """
  @spec fail(String.t()) :: {:retrying, entry()} | {:dropped, entry()} | :unknown
  def fail(request_id) when is_binary(request_id) do
    entries = list()

    case Enum.find(entries, &(&1.request_id == request_id)) do
      nil ->
        :unknown

      entry ->
        attempted = %{entry | attempts: entry.attempts + 1}

        if attempted.attempts >= @max_attempts do
          SessionConfig.put_outbox(Enum.reject(entries, &(&1.request_id == request_id)))
          {:dropped, attempted}
        else
          SessionConfig.put_outbox(
            Enum.map(entries, fn
              %{request_id: ^request_id} -> attempted
              other -> other
            end)
          )

          {:retrying, attempted}
        end
    end
  end

  @doc "Maximum delivery attempts before an entry is dropped."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  @doc "A fresh idempotency key for an instruction."
  @spec new_request_id() :: String.t()
  def new_request_id do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
