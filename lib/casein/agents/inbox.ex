defmodule Casein.Agents.Inbox do
  @moduledoc """
  Agent-to-agent messages, delivered to an address rather than to a terminal.

  Casein's existing way for one agent to reach another is to *type into its
  pane*. That path is unreliable in a way that is invisible when it fails: an
  agent CLI's input box is a TUI, keystrokes race whatever it is drawing, an
  empty box renders the last submitted message as a ghost, and a send that
  lands in the wrong pane is indistinguishable from one that worked. Every
  delivery bug we have had on that path was a delivery bug, not a content bug.

  A message left at an address has none of those failure modes. The recipient
  reads it when it is ready to read, the record is durable, and a message that
  was never collected is visible as exactly that.

  ## Not a new store

  Messages are `Casein.Agents.AgentEvents` rows, the same durable stream that
  already carries clarification requests and their resolutions:

    * `agent.message_sent` — `privacy_class: "operator_content"`, because a
      message body is content, not metadata
    * `agent.message_collected` — metadata-only receipt

  Reusing that stream means no migration, and it inherits the Postgres, SQLite
  (Windows desktop) and in-memory adapters plus the audit trail for free.

  ## Every uncollected message, not the newest one

  `Casein.Agents.AgentEvents.list_open_clarifications/4` projects *newest per
  pane*, which is right for "does this pane need a human?" and wrong for an
  inbox: it would hide every message but the last from a sender that wrote
  twice. Older-but-unread is the normal case for a mailbox, so this module
  projects open-minus-collected with no deduplication at all.

  ## Delivery is not collection

  `send/1` records that a message exists. `collect/3` records that the
  recipient actually read it. Keeping them separate is what makes "sent but
  never read" a visible state instead of an assumption — the question the pane
  path could never answer.

  ## Status honesty (#911)

  Wire status is **queued** (sent, uncollected) or **collected** (recipient
  marked read). `unread?` is true only for queued. Collection clears unread —
  not sending. Never report `collected` for something still queued (visible ≠
  true class).

  ## Constraints carried here (not only in briefs)

  * **Pane writes stay DISABLED** — this module is an addressed store agents
    collect from; do not route through `terminal_send_command` / `send_keys`.
  * **Double-collect is idempotent** — same `message_id` / event id yields one
    receipt (`:duplicate`), never a second delivery.
  * **Do not invent "delivered and read" on send** — send only means queued.
  """

  alias Casein.Agents.{AgentEvent, AgentEvents}
  alias Casein.Agents.Inbox.Address

  @message_type "agent.message_sent"
  @collected_type "agent.message_collected"

  # Prelude caps message text at 4000 display columns; the same bound keeps a
  # runaway paste out of the event stream without truncating real messages.
  @body_limit 4_000
  @summary_limit 200
  @default_limit 50

  @type delivery_status :: :queued | :collected

  @type message :: %{
          id: String.t(),
          from: String.t() | nil,
          to: String.t(),
          body: String.t(),
          sent_at: DateTime.t(),
          message_id: String.t() | nil,
          status: delivery_status(),
          unread?: boolean(),
          collected_at: DateTime.t() | nil
        }
  @doc "Event type recorded when a message is sent."
  @spec message_type() :: String.t()
  def message_type, do: @message_type

  @doc "Event type recorded when a message is collected."
  @spec collected_type() :: String.t()
  def collected_type, do: @collected_type

  @doc "Maximum stored message body length, in characters."
  @spec body_limit() :: pos_integer()
  def body_limit, do: @body_limit

  @doc """
  Leave a message at an address.

  Required: `:workspace_id`, `:to` (a canonical address from
  `Casein.Agents.Inbox.Address`), `:body`. Optional: `:from` (the sender's
  canonical address), `:message_id` (stable id; repeat sends with the same id
  coalesce rather than duplicating), `:tmux_session_id`, `:pane_id`.
  """
  @spec send(map()) :: {:ok, AgentEvent.t(), :inserted | :duplicate} | {:error, atom()}
  def send(attrs) when is_map(attrs) do
    with {:ok, workspace_id} <- required(attrs, :workspace_id),
         {:ok, to} <- Address.validate(value(attrs, :to)),
         {:ok, body} <- validate_body(value(attrs, :body)) do
      message_id = value(attrs, :message_id) || derive_message_id(to, body)
      from = optional_address(value(attrs, :from))

      AgentEvents.append(%{
        workspace_id: workspace_id,
        stream_id: "inbox:#{to}",
        producer: "agent",
        ingress: "terminal_mcp",
        # Idempotency: a retried send with the same id is a duplicate, not a
        # second message. Agents retry; mailboxes should not grow because of it.
        source_event_id: "message:#{message_id}",
        event_type: @message_type,
        privacy_class: "operator_content",
        tmux_session_id: value(attrs, :tmux_session_id),
        pane_id: value(attrs, :pane_id),
        status: "open",
        summary: summary_for(from, to),
        payload: %{
          "schema_version" => 1,
          "message_id" => message_id,
          "to" => to,
          "from" => from,
          "body" => body
        }
      })
    end
  end

  def send(_attrs), do: {:error, :invalid_payload}

  @doc """
  Uncollected messages at an address, oldest first.

  Oldest first because a mailbox is read in the order it was written; the
  newest-first ordering the attention surfaces use is a ranking, and ranking a
  mailbox is how the older message stops being answerable.

  Each message carries honest `#911` lifecycle fields:

    * `status` — `:queued` (uncollected) or `:collected`
    * `unread?` — `true` only while `:queued` (collect clears unread, not send)

  Options: `:limit` (default #{@default_limit}), `:include_collected`.
  """
  @spec list(String.t(), String.t(), keyword()) :: [message()]
  def list(workspace_id, address, opts \\ [])
      when is_binary(workspace_id) and is_binary(address) do
    limit = Keyword.get(opts, :limit, @default_limit)
    include_collected? = Keyword.get(opts, :include_collected, false) == true

    {messages, collected_at} = mailbox_events(workspace_id, address)

    messages
    |> reject_collected_ids(collected_at, include_collected?)
    |> Enum.sort_by(&{&1.occurred_at, &1.inserted_at, &1.id}, :asc)
    |> Enum.take(limit)
    |> Enum.map(&to_message(&1, collected_at))
  end

  @doc """
  Mailbox summary for one address: pending/unread counts never invent "read".

  `pending` / `unread` count **queued** messages only. `collected` counts
  receipts. Sending does not decrement pending — only `collect/3` does.
  """
  @spec summary(String.t(), String.t()) :: %{
          address: String.t(),
          pending: non_neg_integer(),
          unread: non_neg_integer(),
          collected: non_neg_integer()
        }
  def summary(workspace_id, address)
      when is_binary(workspace_id) and is_binary(address) do
    {messages, collected_at} = mailbox_events(workspace_id, address)
    pending = Enum.count(messages, fn ev -> not Map.has_key?(collected_at, ev.id) end)

    %{
      address: address,
      pending: pending,
      # unread tracks pending — collection clears both; send never clears either.
      unread: pending,
      collected: map_size(collected_at)
    }
  end

  @doc """
  Look up one message by stable `message_id` (send-side idempotency key).

  Returns honest status for the sender: `:queued` until collect, then
  `:collected`. Missing id is `{:error, :not_found}` — never faked as collected.
  """
  @spec get_by_message_id(String.t(), String.t()) :: {:ok, message()} | {:error, :not_found}
  def get_by_message_id(workspace_id, message_id)
      when is_binary(workspace_id) and is_binary(message_id) and message_id != "" do
    events = AgentEvents.list_by_event_types(workspace_id, [@message_type, @collected_type])

    collected_at =
      events
      |> Enum.filter(&(&1.event_type == @collected_type))
      |> Map.new(fn ev ->
        {payload_field(ev, "message_event_id"), ev.occurred_at || ev.inserted_at}
      end)

    case Enum.find(events, fn ev ->
           ev.event_type == @message_type and payload_field(ev, "message_id") == message_id
         end) do
      %AgentEvent{} = event -> {:ok, to_message(event, collected_at)}
      _ -> {:error, :not_found}
    end
  end

  def get_by_message_id(_workspace_id, _message_id), do: {:error, :not_found}

  @doc """
  Record that a message was read.

  Idempotent: collecting the same message twice is a duplicate, not a second
  receipt. Accepts either the durable event id or the stable `message_id`
  (same coalescing key as `send/1`).
  """
  @spec collect(String.t(), String.t(), map()) ::
          {:ok, AgentEvent.t(), :inserted | :duplicate} | {:error, atom()}
  def collect(workspace_id, message_ref, attrs \\ %{})
      when is_binary(workspace_id) and is_binary(message_ref) do
    if message_ref == "" do
      {:error, :invalid_message}
    else
      with {:ok, message_event_id, message_id} <- resolve_collect_ref(workspace_id, message_ref) do
        AgentEvents.append(%{
          workspace_id: workspace_id,
          stream_id: "inbox:#{value(attrs, :to) || "unknown"}",
          producer: "agent",
          ingress: "terminal_mcp",
          # Idempotency key is the event id — double-collect cannot mint two receipts.
          source_event_id: "collected:#{message_event_id}",
          event_type: @collected_type,
          privacy_class: "metadata",
          tmux_session_id: value(attrs, :tmux_session_id),
          pane_id: value(attrs, :pane_id),
          status: "collected",
          summary: "Message collected",
          payload: %{
            "schema_version" => 1,
            "message_event_id" => message_event_id,
            "message_id" => message_id
          }
        })
      end
    end
  end

  ## Internals

  defp mailbox_events(workspace_id, address) do
    events = AgentEvents.list_by_event_types(workspace_id, [@message_type, @collected_type])

    collected_at =
      events
      |> Enum.filter(&(&1.event_type == @collected_type))
      |> Map.new(fn ev ->
        {payload_field(ev, "message_event_id"), ev.occurred_at || ev.inserted_at}
      end)

    messages =
      events
      |> Enum.filter(&(&1.event_type == @message_type))
      |> Enum.filter(&(payload_field(&1, "to") == address))

    {messages, collected_at}
  end

  defp reject_collected_ids(events, _collected_at, true), do: events

  defp reject_collected_ids(events, collected_at, false),
    do: Enum.reject(events, &Map.has_key?(collected_at, &1.id))

  defp to_message(%AgentEvent{} = event, collected_at) when is_map(collected_at) do
    collected_at_ts = Map.get(collected_at, event.id)
    # status is derived only from collection receipts — never from send alone.
    status = if collected_at_ts, do: :collected, else: :queued

    %{
      id: event.id,
      from: payload_field(event, "from"),
      to: payload_field(event, "to"),
      body: payload_field(event, "body") || "",
      sent_at: event.occurred_at,
      message_id: payload_field(event, "message_id"),
      status: status,
      # unread? mirrors queued only — collect clears unread (#911).
      unread?: status == :queued,
      collected_at: collected_at_ts
    }
  end

  defp resolve_collect_ref(workspace_id, ref) do
    events = AgentEvents.list_by_event_types(workspace_id, [@message_type])

    by_id = Enum.find(events, &(&1.id == ref))
    by_message_id = Enum.find(events, &(payload_field(&1, "message_id") == ref))

    case by_id || by_message_id do
      %AgentEvent{} = event ->
        {:ok, event.id, payload_field(event, "message_id")}

      _ ->
        # Unknown ref still keys a receipt by the given string so retries stay
        # idempotent even if the original send was never visible to this node.
        {:ok, ref, nil}
    end
  end

  defp payload_field(%AgentEvent{payload: payload}, key) when is_map(payload) do
    Map.get(payload, key)
  end

  defp payload_field(_event, _key), do: nil

  # The address pair, never the body: summaries land in generic surfaces that
  # are not entitled to operator content.
  defp summary_for(nil, to), do: String.slice("Message to #{to}", 0, @summary_limit)
  defp summary_for(from, to), do: String.slice("Message #{from} -> #{to}", 0, @summary_limit)

  # A caller that supplies no id still gets coalescing of an identical retry,
  # without collapsing two genuinely different messages to the same address.
  defp derive_message_id(to, body) do
    :crypto.hash(:sha256, to <> "\n" <> body)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp validate_body(body) when is_binary(body) do
    case String.trim(body) do
      "" -> {:error, :empty_body}
      trimmed -> {:ok, String.slice(trimmed, 0, @body_limit)}
    end
  end

  defp validate_body(_body), do: {:error, :invalid_body}

  defp optional_address(value) do
    case Address.validate(value) do
      {:ok, address} -> address
      {:error, _reason} -> nil
    end
  end

  # Literal error atoms rather than `:"missing_#{key}"`: interpolating a
  # variable into an atom is how an atom table gets exhausted, and the compiler
  # cannot prove this key is always a literal.
  defp required(attrs, :workspace_id) do
    case value(attrs, :workspace_id) do
      binary when is_binary(binary) and binary != "" -> {:ok, binary}
      _ -> {:error, :missing_workspace_id}
    end
  end

  defp value(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end
end
