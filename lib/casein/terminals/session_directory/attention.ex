defmodule Casein.Terminals.SessionDirectory.Attention do
  @moduledoc """
  Provider-neutral attention classification for session picker rows.

  The classifier consumes the semantic metadata already attached by
  `Casein.Terminals.SessionDirectory`: reported agent state and the stable,
  quantized quiet flag. It deliberately does not infer an agent provider or
  inspect host processes. tmux remains the session transport, not agent identity.

  `group/1` is a stable partition. Callers can retain their existing recency or
  name ordering before grouping into `:needs_you`, `:working`, and `:recent`.
  """

  alias Casein.Terminals.Session.Info, as: SessionInfo

  @type section :: :needs_you | :working | :recent

  @type reason ::
          :blocked
          | :error
          | :completed
          | :quiet
          | :working
          | :recent

  @type classification :: %{section: section(), reason: reason()}
  @type groups :: %{
          needs_you: [SessionInfo.t()],
          working: [SessionInfo.t()],
          recent: [SessionInfo.t()]
        }

  @doc "Classifies one session using provider-neutral directory metadata."
  @spec classify(SessionInfo.t() | map()) :: classification()
  def classify(session) when is_map(session) do
    windows =
      case value(session, :windows) do
        windows when is_list(windows) -> windows
        _ -> session |> value(:metadata, %{}) |> value(:windows, []) |> list_or_empty()
      end

    states = Enum.map(windows, &normalize_state(value(&1, :agent_state)))

    cond do
      lifecycle_status(session) == :error or :blocked in states ->
        %{section: :needs_you, reason: if(:blocked in states, do: :blocked, else: :error)}

      :done in states ->
        %{section: :needs_you, reason: :completed}

      Enum.any?(windows, &truthy?(value(&1, :quiet))) ->
        %{section: :needs_you, reason: :quiet}

      :working in states ->
        %{section: :working, reason: :working}

      true ->
        %{section: :recent, reason: :recent}
    end
  end

  @doc "Stable-partitions sessions into the three picker sections."
  @spec group([SessionInfo.t() | map()]) :: groups()
  def group(sessions) when is_list(sessions) do
    grouped = Enum.group_by(sessions, &classify(&1).section)

    %{
      needs_you: Map.get(grouped, :needs_you, []),
      working: Map.get(grouped, :working, []),
      recent: Map.get(grouped, :recent, [])
    }
  end

  defp lifecycle_status(session) do
    case value(session, :status) do
      status when status in [:error, "error", :failed, "failed"] -> :error
      _ -> :other
    end
  end

  defp normalize_state(state) when state in [:blocked, "blocked", :attention, "attention"],
    do: :blocked

  defp normalize_state(state) when state in [:done, "done", :completed, "completed"],
    do: :done

  defp normalize_state(state) when state in [:working, "working", :running, "running"],
    do: :working

  defp normalize_state(_state), do: :other

  defp value(map, key, default \\ nil) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp list_or_empty(value) when is_list(value), do: value
  defp list_or_empty(_value), do: []

  defp truthy?(value) when value in [true, 1, "1", "true", "yes", "on"], do: true
  defp truthy?(_value), do: false
end
