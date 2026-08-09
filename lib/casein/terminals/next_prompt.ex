defmodule Casein.Terminals.NextPrompt do
  @moduledoc """
  A single sticky operator message per agent pane, delivered on the pane's next
  semantic-state edge.

  ## The problem this solves

  An orchestrator that notices something mid-turn — "the branch moved, rebase
  before you push" — has no good way to say it. Typing into the agent pane while
  the runtime is working either lands in a composer nobody submits, gets eaten
  by a TUI that is not reading keys, or interrupts a turn that was about to
  succeed. The existing human-input tools run the other direction (agent asks,
  human answers), and `Casein.Mobile.Clarification` is a *question* with an
  answer, not a message with a delivery time.

  So the message gets held until the agent is free, and "held until free" is
  exactly the piece that did not exist.

  ## What this is not

  Not a mailbox. There is **at most one** pending message per
  `{tmux_session, pane_id}` and setting a second one replaces the first —
  latest wins, no FIFO, no priorities. That is a deliberate constraint, not a
  missing feature: a queue of stale instructions delivered in one burst is worse
  for an agent than the newest instruction alone, and an operator who sends a
  correction almost always means it to supersede what they said thirty seconds
  earlier. `coalesce_key` exists so a caller can tell *whose* message is
  pending and clear only its own, not to partition the slot into several.

  ## Delivery

  Entries are held in memory keyed by `{tmux_session, pane_id}` and are dropped,
  never delivered, when any of the following happens first:

    * the bound `agent_session_id` changes — the runtime restarted, and a
      message written for the previous session is addressed to an agent that no
      longer exists;
    * the pane disappears from its session (`prune_session/2`);
    * `expires_at` passes (24h by default).

  `deliver_when` names the edge to wait for:

    * `:next_idle` (default) — the first transition into `:idle` **or**
      `:done`. Read it as "when the agent stops working", which is what
      operators mean, rather than as the literal `:idle` report: Claude's hook
      only emits `idle` on `SessionStart`/`SessionEnd`, so a literal reading
      would make the default deliver_when almost never fire. Every wired runtime
      ends a turn with `done` (`Stop`).
    * `:next_blocked` — the agent hit a permission prompt or a wedged turn.
    * `:next_done` — a completed turn only.

  Nothing here interrupts a working agent. There is no `interrupt_if_working`,
  by design: the entire value of the feature is that the operator can speak
  without deciding whether now is a safe moment.

  When the target pane is *already* in the requested state at set time, the
  message is delivered immediately rather than parked waiting for an edge that
  has already passed. A message silently held forever because the agent went
  idle a second before the operator hit send is the failure mode this avoids.

  ## Delivery is best-effort, and says so

  Injection goes through `Casein.Terminals.PaneSubmit`, which confirms the
  submit actually landed instead of trusting tmux's exit code. A delivery that
  cannot be confirmed is retried on the pane's next qualifying edge, once; after
  that the entry is dropped and an `agent.next_prompt_failed` audit row records
  it. Casein does not have a synthetic user-turn injection path across runtimes,
  so pasting into the pane is the transport, with the limits that implies: a
  runtime that is not accepting keyboard input cannot be reached this way.
  """

  alias Casein.Terminals.NextPrompt.Server

  @deliver_when [:next_idle, :next_blocked, :next_done]
  @default_deliver_when :next_idle
  @default_ttl_seconds 86_400
  @max_ttl_seconds 604_800
  @text_limit 8_000
  @coalesce_key_limit 120

  @type deliver_when :: :next_idle | :next_blocked | :next_done

  @type entry :: %{
          workspace_id: String.t() | nil,
          tmux_session: String.t(),
          pane_id: String.t(),
          text: String.t(),
          deliver_when: deliver_when(),
          coalesce_key: String.t() | nil,
          agent_session_id: String.t() | nil,
          set_by: String.t() | nil,
          set_at: DateTime.t(),
          expires_at: DateTime.t() | nil,
          attempts: non_neg_integer(),
          revision: pos_integer()
        }

  def start_link(opts \\ []), do: Server.start_link(opts)

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "The accepted `deliver_when` values, as atoms."
  @spec deliver_when_values() :: [deliver_when()]
  def deliver_when_values, do: @deliver_when

  @doc "The default `deliver_when` when a caller does not name one."
  @spec default_deliver_when() :: deliver_when()
  def default_deliver_when, do: @default_deliver_when

  @doc "Maximum accepted prompt length, in bytes."
  @spec text_limit() :: pos_integer()
  def text_limit, do: @text_limit

  @doc "Default time-to-live for a pending prompt, in seconds."
  @spec default_ttl_seconds() :: pos_integer()
  def default_ttl_seconds, do: @default_ttl_seconds

  @doc """
  The reported agent states that satisfy a `deliver_when`.

  See the module doc for why `:next_idle` covers `:done` as well as `:idle`.
  """
  @spec target_states(deliver_when()) :: [Casein.Terminals.AgentState.state()]
  def target_states(:next_idle), do: [:idle, :done]
  def target_states(:next_blocked), do: [:blocked]
  def target_states(:next_done), do: [:done]

  @doc """
  Parse a caller-supplied `deliver_when`, returning `:error` for unknown values.

  Unknown values are rejected rather than defaulted: silently downgrading
  `"next_blocked"` (a typo away from `"blocked"`) to the default would deliver
  an operator's message on the wrong edge and look like it worked.
  """
  @spec parse_deliver_when(term()) :: {:ok, deliver_when()} | :error
  def parse_deliver_when(nil), do: {:ok, @default_deliver_when}
  def parse_deliver_when(value) when value in @deliver_when, do: {:ok, value}

  def parse_deliver_when(value) when is_binary(value) do
    case Enum.find(@deliver_when, &(Atom.to_string(&1) == value)) do
      nil -> :error
      parsed -> {:ok, parsed}
    end
  end

  def parse_deliver_when(_value), do: :error

  @doc "Clamp a caller-supplied TTL into `1..#{@max_ttl_seconds}` seconds."
  @spec expires_at(term(), DateTime.t()) :: DateTime.t()
  def expires_at(seconds, now \\ DateTime.utc_now())

  def expires_at(seconds, now) when is_integer(seconds) and seconds > 0 do
    DateTime.add(now, min(seconds, @max_ttl_seconds), :second)
  end

  def expires_at(_seconds, now), do: DateTime.add(now, @default_ttl_seconds, :second)

  @doc """
  Whether an entry has outlived its `expires_at`.

  An entry without an expiry never expires; callers always supply one today, but
  the store must not delete an entry merely because a field is missing.
  """
  @spec expired?(entry(), DateTime.t()) :: boolean()
  def expired?(%{expires_at: %DateTime{} = at}, now), do: DateTime.compare(now, at) != :lt
  def expired?(_entry, _now), do: false

  @doc """
  Whether a state report belongs to a different agent session than the one the
  entry was written for.

  Only a *known* mismatch counts. A report with no `agent_session_id` (a
  runtime without hooks, or a dispatch-sourced report) is not evidence that the
  session changed, and treating it as one would silently discard every pending
  prompt for runtimes that do not report the field.
  """
  @spec superseded?(entry(), map()) :: boolean()
  def superseded?(%{agent_session_id: bound}, %{agent_session_id: reported})
      when is_binary(bound) and is_binary(reported) and bound != "" and reported != "" do
    bound != reported
  end

  def superseded?(_entry, _report), do: false

  @doc "Whether a state report is the edge this entry is waiting for."
  @spec deliverable?(entry(), map(), DateTime.t()) :: boolean()
  def deliverable?(entry, %{state: state} = report, now) do
    not expired?(entry, now) and not superseded?(entry, report) and
      state in target_states(entry.deliver_when)
  end

  def deliverable?(_entry, _report, _now), do: false

  @doc """
  Stage a sticky prompt for a pane, replacing whatever was pending for it.

  Options: `:workspace_id`, `:deliver_when`, `:coalesce_key`,
  `:agent_session_id`, `:expires_at`, `:set_by`, and `:current_state` (the
  pane's already-resolved semantic state, used to decide whether the requested
  edge has already arrived).

  Returns `{:ok, %{status: :pending | :delivered, entry: entry, replaced: prev}}`.
  """
  @spec set(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def set(tmux_session, pane_id, text, opts \\ [])
      when is_binary(tmux_session) and is_binary(pane_id) and is_binary(text) and is_list(opts) do
    with {:ok, text} <- validate_text(text),
         {:ok, deliver_when} <- validate_deliver_when(Keyword.get(opts, :deliver_when)) do
      Server.set(tmux_session, pane_id, text, Keyword.put(opts, :deliver_when, deliver_when))
    end
  end

  defp validate_deliver_when(value) do
    case parse_deliver_when(value) do
      {:ok, deliver_when} -> {:ok, deliver_when}
      :error -> {:error, :invalid_deliver_when}
    end
  end

  @doc "The pending entry for a pane, or nil."
  @spec get(String.t(), String.t()) :: entry() | nil
  def get(tmux_session, pane_id) when is_binary(tmux_session) and is_binary(pane_id) do
    Server.get(tmux_session, pane_id)
  end

  @doc """
  Drop the pending entry for a pane.

  With `coalesce_key:`, only clears when the pending entry carries that key, so
  a caller can retract its own message without stepping on one a different
  orchestrator staged in the meantime. Returns the cleared entry, or nil.
  """
  @spec clear(String.t(), String.t(), keyword()) :: entry() | nil
  def clear(tmux_session, pane_id, opts \\ [])
      when is_binary(tmux_session) and is_binary(pane_id) and is_list(opts) do
    Server.clear(tmux_session, pane_id, Keyword.get(opts, :coalesce_key))
  end

  @doc "Pending entries for a session, keyed by pane id."
  @spec for_session(String.t()) :: %{optional(String.t()) => entry()}
  def for_session(tmux_session) when is_binary(tmux_session) do
    Server.for_session(tmux_session)
  end

  @doc "Drop pending entries for panes that no longer exist in a session."
  @spec prune_session(String.t(), [String.t()]) :: :ok
  def prune_session(tmux_session, pane_ids) when is_binary(tmux_session) and is_list(pane_ids) do
    Server.prune_session(tmux_session, pane_ids)
  end

  @doc false
  @spec clear() :: :ok
  def clear, do: Server.clear_all()

  @doc """
  Flag panes in a topology map that have a prompt waiting.

  Only truthy flags are written, so payloads and stable hashes are unchanged for
  the overwhelmingly common case of nothing pending.
  """
  @spec enrich_topology(map(), String.t()) :: map()
  def enrich_topology(%{panes: panes} = topology, tmux_session)
      when is_list(panes) and is_binary(tmux_session) do
    case for_session(tmux_session) do
      pending when map_size(pending) == 0 -> topology
      pending -> %{topology | panes: Enum.map(panes, &flag_pane(&1, pending))}
    end
  end

  def enrich_topology(topology, _tmux_session), do: topology

  defp flag_pane(pane, pending) when is_map(pane) do
    case Map.get(pending, Map.get(pane, :id) || Map.get(pane, "id")) do
      nil -> pane
      entry -> pane |> Map.put(:pending_next_prompt, true) |> put_deliver_when(entry)
    end
  end

  defp flag_pane(pane, _pending), do: pane

  defp put_deliver_when(pane, %{deliver_when: deliver_when}) do
    Map.put(pane, :pending_next_prompt_deliver_when, Atom.to_string(deliver_when))
  end

  defp validate_text(text) do
    case String.trim(text) do
      "" ->
        {:error, :empty_next_prompt}

      trimmed ->
        if byte_size(trimmed) > @text_limit,
          do: {:error, {:next_prompt_too_long, @text_limit}},
          else: {:ok, trimmed}
    end
  end

  @doc false
  @spec normalize_coalesce_key(term()) :: String.t() | nil
  def normalize_coalesce_key(key) when is_binary(key) do
    case String.trim(key) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @coalesce_key_limit)
    end
  end

  def normalize_coalesce_key(_key), do: nil
end
