defmodule Casein.Terminals.ClipboardHistory do
  @moduledoc """
  Recent per-workspace clipboard copies made *by* terminal programs.

  When an agent CLI copies something it emits OSC 52; the viewer extracts that
  and asks the browser to write it to the system clipboard. On iOS that write is
  frequently refused — an unattended write has no user activation — so the copy
  used to exist only as a single pending value that was lost if the toast
  expired before the operator tapped it.

  This feed makes those copies retrievable instead of racing them: every OSC 52
  payload is retained here, so a missed toast, a backgrounded tab, or several
  copies in a row are all recoverable, and a copy made on the box can be picked
  up from a different device viewing the same workspace.

  Bounded and in-memory by design — clipboard contents are frequently sensitive
  and have no business being durable. Nothing here is persisted, and the text is
  never written to logs or audit.

  ## Message shape

  Subscribers of `subscribe/1` receive `{:clipboard_history, entry}` on every
  recorded copy.
  """

  use GenServer

  alias Phoenix.PubSub

  @topic_prefix "clipboard_history:"
  @default_limit 20
  @max_per_workspace 20

  # Clipboard payloads arrive capped at 256 KB of base64 (~192 KB decoded).
  # Retaining several of those per workspace would be a meaningful chunk of
  # memory, and the text has to reach the DOM intact for the copy button to work
  # inside the click (a server round-trip would land outside the user gesture
  # and hit the very restriction this feature exists to route around). Truncate
  # so both the process state and the rendered payload stay predictable.
  @max_text_bytes 64 * 1024

  @type entry :: %{
          id: String.t(),
          workspace_id: String.t(),
          pane_id: String.t() | nil,
          pane_label: String.t() | nil,
          text: String.t(),
          byte_size: non_neg_integer(),
          truncated?: boolean(),
          inserted_at: DateTime.t()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec subscribe(String.t()) :: :ok
  def subscribe(workspace_id) when is_binary(workspace_id) do
    PubSub.subscribe(Casein.PubSub, topic(workspace_id))
  end

  @doc """
  Record a copy. Returns the stored entry, or `nil` when there is nothing worth
  storing (blank text, or no workspace to attribute it to).
  """
  @spec record(map()) :: entry() | nil
  def record(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:record, attrs})
  end

  @spec recent(String.t(), pos_integer()) :: [entry()]
  def recent(workspace_id, limit \\ @default_limit) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:recent, workspace_id, limit})
  end

  @doc """
  How many copies are retained for a workspace.

  Lets a viewer badge the drawer without pulling the payloads into socket
  assigns — the text is only loaded when the drawer is actually opened.
  """
  @spec count(String.t()) :: non_neg_integer()
  def count(workspace_id) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:count, workspace_id})
  end

  @doc "Drop a workspace's history — the operator-facing 'clear clipboard' action."
  @spec forget(String.t()) :: :ok
  def forget(workspace_id) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:forget, workspace_id})
  end

  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:recent, workspace_id, limit}, _from, state) do
    {:reply, state |> Map.get(workspace_id, []) |> Enum.take(limit), state}
  end

  def handle_call({:count, workspace_id}, _from, state) do
    {:reply, state |> Map.get(workspace_id, []) |> length(), state}
  end

  def handle_call({:forget, workspace_id}, _from, state) do
    {:reply, :ok, Map.delete(state, workspace_id)}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{}}

  def handle_call({:record, attrs}, _from, state) do
    case build_entry(attrs) do
      nil ->
        {:reply, nil, state}

      entry ->
        existing = Map.get(state, entry.workspace_id, [])

        list =
          [entry | Enum.reject(existing, &(&1.text == entry.text))]
          |> Enum.take(@max_per_workspace)

        PubSub.broadcast(
          Casein.PubSub,
          topic(entry.workspace_id),
          {:clipboard_history, entry}
        )

        {:reply, entry, Map.put(state, entry.workspace_id, list)}
    end
  end

  defp build_entry(attrs) do
    workspace_id = optional_string(Map.get(attrs, :workspace_id))
    text = Map.get(attrs, :text)

    if is_binary(workspace_id) and is_binary(text) and String.trim(text) != "" do
      {text, truncated?} = truncate(text)

      %{
        id: Map.get(attrs, :id, Ecto.UUID.generate()),
        workspace_id: workspace_id,
        pane_id: optional_string(Map.get(attrs, :pane_id)),
        pane_label: optional_string(Map.get(attrs, :pane_label)),
        text: text,
        byte_size: byte_size(text),
        truncated?: truncated?,
        inserted_at: Map.get(attrs, :inserted_at, DateTime.utc_now())
      }
    end
  end

  # Cut on a character boundary so the retained text stays valid UTF-8 for the
  # DOM; binary_part/3 alone can split a multi-byte grapheme.
  defp truncate(text) when byte_size(text) <= @max_text_bytes, do: {text, false}

  defp truncate(text) do
    truncated =
      text
      |> binary_part(0, @max_text_bytes)
      |> String.chunk(:valid)
      |> Enum.take_while(&String.valid?/1)
      |> Enum.join()

    {truncated, true}
  end

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      string -> string
    end
  end

  defp optional_string(_), do: nil

  defp topic(workspace_id), do: @topic_prefix <> workspace_id
end
