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

  @type message :: %{
          id: String.t(),
          from: String.t() | nil,
          to: String.t(),
          body: String.t(),
          sent_at: DateTime.t(),
          message_id: String.t() | nil
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

  Options: `:limit` (default #{@default_limit}), `:include_collected`.
  """
  @spec list(String.t(), String.t(), keyword()) :: [message()]
  def list(workspace_id, address, opts \\ [])
      when is_binary(workspace_id) and is_binary(address) do
    limit = Keyword.get(opts, :limit, @default_limit)
    include_collected? = Keyword.get(opts, :include_collected, false) == true

    events =
      AgentEvents.list_by_event_types(workspace_id, [@message_type, @collected_type])

    collected =
      events
      |> Enum.filter(&(&1.event_type == @collected_type))
      |> MapSet.new(&payload_field(&1, "message_event_id"))

    events
    |> Enum.filter(&(&1.event_type == @message_type))
    |> Enum.filter(&(payload_field(&1, "to") == address))
    |> reject_collected(collected, include_collected?)
    |> Enum.sort_by(&{&1.occurred_at, &1.inserted_at, &1.id}, :asc)
    |> Enum.take(limit)
    |> Enum.map(&to_message/1)
  end

  @doc """
  Record that a message was read.

  Idempotent: collecting the same message twice is a duplicate, not a second
  receipt.
  """
  @spec collect(String.t(), String.t(), map()) ::
          {:ok, AgentEvent.t(), :inserted | :duplicate} | {:error, atom()}
  def collect(workspace_id, message_event_id, attrs \\ %{})
      when is_binary(workspace_id) and is_binary(message_event_id) do
    if message_event_id == "" do
      {:error, :invalid_message}
    else
      AgentEvents.append(%{
        workspace_id: workspace_id,
        stream_id: "inbox:#{value(attrs, :to) || "unknown"}",
        producer: "agent",
        ingress: "terminal_mcp",
        source_event_id: "collected:#{message_event_id}",
        event_type: @collected_type,
        privacy_class: "metadata",
        tmux_session_id: value(attrs, :tmux_session_id),
        pane_id: value(attrs, :pane_id),
        status: "collected",
        summary: "Message collected",
        payload: %{
          "schema_version" => 1,
          "message_event_id" => message_event_id
        }
      })
    end
  end

  ## Internals

  defp reject_collected(events, _collected, true), do: events

  defp reject_collected(events, collected, false),
    do: Enum.reject(events, &MapSet.member?(collected, &1.id))

  defp to_message(%AgentEvent{} = event) do
    %{
      id: event.id,
      from: payload_field(event, "from"),
      to: payload_field(event, "to"),
      body: payload_field(event, "body") || "",
      sent_at: event.occurred_at,
      message_id: payload_field(event, "message_id")
    }
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
