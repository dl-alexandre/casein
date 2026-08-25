defmodule Casein.Agents.Inbox.Address do
  @moduledoc """
  Canonical recipients for `Casein.Agents.Inbox`, and the refusal to guess one.

  Three forms:

    * `pane:%3` — one exact pane. Ephemeral: a respawn orphans this mailbox.
    * `worktree:/abs/path` — whoever is working in that checkout. Survives a
      restart into a new pane in the same tree; a fresh worktree orphans it.
    * `handle:<handle_id>` — a durable work handle. Survives pane respawn
      when the successor reattaches the same handle. This is the address for
      a long-lived role (coordinator, factory manager).

  ## Ambiguity is an error, not a choice

  An orchestrator naturally writes the name it knows — `worker-2`, `api`, a
  window title. Resolving that against a live topology can match more than one
  window, and picking the best match is how a message reaches the wrong agent.
  A misdelivered instruction is worse than an undelivered one: the sender
  believes it landed, and the recipient acts on work that was not theirs.

  So `resolve/2` returns `{:error, {:ambiguous, candidates}}` and lets the
  caller disambiguate with an exact pane id. This mirrors the refusal in
  `Casein.Agents.Transcripts.Discovery`, for the same reason.
  """

  alias Casein.Terminals.PaneState

  @pane_prefix "pane:"
  @worktree_prefix "worktree:"
  @handle_prefix "handle:"

  @type t :: String.t()
  @type candidate :: %{address: t(), name: String.t() | nil, pane_id: String.t() | nil}

  @doc "A canonical address for an exact pane."
  @spec for_pane(String.t()) :: t()
  def for_pane(pane_id) when is_binary(pane_id), do: @pane_prefix <> pane_id

  @doc "A canonical address for everyone working in a checkout."
  @spec for_worktree(String.t()) :: t()
  def for_worktree(path) when is_binary(path), do: @worktree_prefix <> Path.expand(path)

  @doc "A canonical address for a durable work handle."
  @spec for_handle(String.t()) :: t()
  def for_handle(handle_id) when is_binary(handle_id), do: @handle_prefix <> handle_id

  @doc "The pane id inside a `pane:%N` address, or nil."
  @spec pane_id(t()) :: String.t() | nil
  def pane_id(address) when is_binary(address) do
    rest_after(address, @pane_prefix)
  end

  def pane_id(_address), do: nil

  @doc "The handle id inside a `handle:<id>` address, or nil."
  @spec handle_id(t()) :: String.t() | nil
  def handle_id(address) when is_binary(address) do
    rest_after(address, @handle_prefix)
  end

  def handle_id(_address), do: nil

  @doc """
  Accept an already-canonical address.

  Deliberately strict: this is the last gate before a message is stored under
  an address, and a typo that silently becomes a valid-looking address creates
  a mailbox nobody reads.
  """
  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_address}
  def validate(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      String.starts_with?(trimmed, @pane_prefix) and rest_present?(trimmed, @pane_prefix) ->
        {:ok, trimmed}

      String.starts_with?(trimmed, @worktree_prefix) and rest_present?(trimmed, @worktree_prefix) ->
        {:ok, trimmed}

      String.starts_with?(trimmed, @handle_prefix) and rest_present?(trimmed, @handle_prefix) ->
        {:ok, trimmed}

      true ->
        {:error, :invalid_address}
    end
  end

  def validate(_value), do: {:error, :invalid_address}

  @doc """
  Resolve what a caller typed against a topology.

  Accepts an already-canonical address (returned unchanged), an exact pane id
  (`%3`), or a window name. A window name matching more than one agent window
  is refused with its candidates rather than resolved to the best match.
  """
  @spec resolve(term(), map()) ::
          {:ok, t()}
          | {:error, :invalid_address | :unknown_recipient | {:ambiguous, [candidate()]}}
  def resolve(value, topology) when is_binary(value) and is_map(topology) do
    trimmed = String.trim(value)

    case validate(trimmed) do
      {:ok, address} -> resolve_canonical(address, topology)
      {:error, _reason} -> resolve_loose(trimmed, topology)
    end
  end

  def resolve(_value, _topology), do: {:error, :invalid_address}

  ## Internals

  defp resolve_canonical(address, topology) do
    case pane_id(address) do
      nil ->
        {:ok, address}

      pane ->
        if pane_in_topology?(pane, topology),
          do: {:ok, address},
          else: {:error, :unknown_recipient}
    end
  end

  defp resolve_loose("", _topology), do: {:error, :invalid_address}

  defp resolve_loose(value, topology) do
    panes = Map.get(topology, :panes) || Map.get(topology, "panes") || []

    cond do
      pane_id?(value) and Enum.any?(panes, &(PaneState.map_get(&1, :id) == value)) ->
        {:ok, for_pane(value)}

      true ->
        by_name(value, topology, panes)
    end
  end

  defp by_name(value, topology, panes) do
    windows = Map.get(topology, :windows) || Map.get(topology, "windows") || []
    downcased = String.downcase(value)

    matches =
      windows
      |> Enum.filter(fn window ->
        name = PaneState.map_get(window, :name)
        is_binary(name) and String.downcase(name) == downcased
      end)
      |> Enum.map(&candidate_for(&1, panes))
      |> Enum.reject(&is_nil/1)

    case matches do
      [] -> {:error, :unknown_recipient}
      [one] -> {:ok, one.address}
      many -> {:error, {:ambiguous, many}}
    end
  end

  defp candidate_for(window, _panes) do
    case PaneState.agent_or_active_pane(window) do
      nil ->
        nil

      pane ->
        case PaneState.map_get(pane, :id) do
          id when is_binary(id) and id != "" ->
            %{address: for_pane(id), name: PaneState.map_get(window, :name), pane_id: id}

          _ ->
            nil
        end
    end
  end

  defp pane_id?(value), do: String.starts_with?(value, "%")

  defp pane_in_topology?(pane_id, topology) do
    panes = Map.get(topology, :panes) || Map.get(topology, "panes") || []
    Enum.any?(panes, &(PaneState.map_get(&1, :id) == pane_id))
  end

  defp rest_after(value, prefix) do
    if String.starts_with?(value, prefix) do
      rest = value |> String.replace_prefix(prefix, "") |> String.trim()
      if rest == "", do: nil, else: rest
    else
      nil
    end
  end

  defp rest_present?(value, prefix) do
    rest_after(value, prefix) != nil
  end
end
