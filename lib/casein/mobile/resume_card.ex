defmodule Casein.Mobile.ResumeCard do
  @moduledoc """
  Versioned, origin-qualified resume metadata projected over a `Mobile.Card`.

  This is deliberately a projection, not a second task store. It separates the
  user-facing semantic state from phase, reachability, and freshness, and only
  carries an allowlisted navigation locator.
  """

  alias Casein.Origin

  @version 1
  @locator_keys ~w(tmux_session window pane tab artifact)a
  @tabs ~w(terminal files search diff artifacts run proposals logs history)
  @task_types ~w(run command agent_task)
  @max_locator_value 256

  @type t :: %{
          required(:version) => 1,
          required(:origin) => %{id: String.t(), display_name: String.t()},
          required(:card_id) => String.t(),
          required(:state) => String.t(),
          required(:phase) => String.t(),
          required(:availability) => String.t(),
          required(:freshness) => %{kind: String.t(), observed_at: DateTime.t() | nil},
          required(:task_ref) => map() | nil,
          required(:locator) => map()
        }

  @spec project(map()) :: t()
  def project(card) when is_map(card) do
    origin = Origin.public_descriptor()
    task_ref = task_ref(card)

    %{
      version: @version,
      origin: origin,
      card_id: text(card, :id),
      state: semantic_state(card),
      phase: phase(card),
      availability: availability(card),
      freshness: %{kind: "live", observed_at: value(card, :updated_at)},
      task_ref: task_ref,
      locator: locator(card, origin.id, task_ref)
    }
  end

  @doc "Build an origin-qualified, credential-free review deep link."
  @spec deep_link(map()) :: String.t()
  def deep_link(card) when is_map(card) do
    resume = project(card)

    query =
      resume.locator
      |> Enum.flat_map(fn
        {:task_ref, %{type: type, id: id}} -> [{"task_type", type}, {"task_id", id}]
        {key, value} when is_binary(value) -> [{Atom.to_string(key), value}]
        _entry -> []
      end)
      |> URI.encode_query()

    base = "devide://review/#{URI.encode_www_form(resume.card_id)}"
    if query == "", do: base, else: base <> "?" <> query
  end

  @spec semantic_state(map()) :: String.t()
  def semantic_state(card) do
    type = normalized(card, :type)
    status = normalized(card, :status)
    kind = normalized(card, :kind)

    cond do
      type == "needs_review" or kind == "approval_required" -> "needs_attention"
      type == "connection_issue" -> "needs_attention"
      status in ~w(failed error timed_out timeout) -> "failed"
      status in ~w(ready ready_to_review review) -> "ready_to_review"
      status in ~w(completed succeeded done) -> "completed"
      type == "workspace_idle" -> "completed"
      true -> "working"
    end
  end

  @spec phase(map()) :: String.t()
  def phase(card) do
    raw =
      nested(card, [:meta, :run_phase]) ||
        nested(card, [:context, :phase]) ||
        value(card, :phase)

    cond do
      normalized(card, :type) == "needs_review" -> "review"
      contains?(raw, "test") -> "testing"
      contains?(raw, "plan") -> "planning"
      contains?(raw, "deploy") -> "deploying"
      contains?(raw, "review") -> "review"
      contains?(raw, "execut") or contains?(raw, "run") -> "executing"
      normalized(card, :type) == "workspace_idle" -> "idle"
      semantic_state(card) == "completed" -> "complete"
      true -> "unknown"
    end
  end

  @spec availability(map()) :: String.t()
  def availability(card) do
    if normalized(card, :type) == "connection_issue" do
      case normalized(nested(card, [:meta, :reason])) do
        reason when reason in ~w(token_revoked invalid_token pairing_expired) ->
          "reauthentication_required"

        _ ->
          "offline_resumable"
      end
    else
      "live"
    end
  end

  defp task_ref(card) do
    explicit = nested(card, [:context, :task_ref]) || nested(card, [:meta, :task_ref])

    case normalize_task_ref(explicit) do
      nil ->
        case first_text([
               nested(card, [:context, :command_id]),
               nested(card, [:meta, :command_id])
             ]) do
          nil -> nil
          id -> %{type: "command", id: id}
        end

      task_ref ->
        task_ref
    end
  end

  defp normalize_task_ref(task_ref) when is_map(task_ref) do
    type = task_ref |> value(:type) |> normalized()
    id = task_ref |> value(:id) |> bounded_text()

    if type in @task_types and is_binary(id), do: %{type: type, id: id}
  end

  defp normalize_task_ref(_task_ref), do: nil

  defp locator(card, origin_id, task_ref) do
    source = nested(card, [:context, :locator]) || %{}
    context = value(card, :context) || %{}
    meta = value(card, :meta) || %{}

    %{
      origin_id: origin_id,
      workspace_id: bounded_text(value(card, :workspace_id)),
      task_ref: task_ref,
      session_id: bounded_text(value(card, :session_id)),
      tmux_session: locator_value(:tmux_session, source, context, meta),
      window: locator_value(:window, source, context, meta),
      pane: locator_value(:pane, source, context, meta),
      tab: locator_value(:tab, source, context, meta),
      artifact: locator_value(:artifact, source, context, meta)
    }
    |> Enum.filter(fn
      {:tab, tab} -> tab in @tabs
      {_key, value} -> not is_nil(value)
    end)
    |> Map.new()
  end

  defp locator_value(key, source, context, meta) when key in @locator_keys do
    aliases =
      case key do
        :window -> [:window, :window_id]
        :pane -> [:pane, :pane_id]
        :artifact -> [:artifact, :artifact_id]
        other -> [other]
      end

    aliases
    |> Enum.flat_map(fn alias_key ->
      [value(source, alias_key), value(context, alias_key), value(meta, alias_key)]
    end)
    |> first_text()
    |> bounded_text()
  end

  defp text(map, key), do: value(map, key) |> to_string()

  defp normalized(map, key) when is_map(map), do: map |> value(key) |> normalized()
  defp normalized(nil), do: ""
  defp normalized(value) when is_atom(value), do: value |> Atom.to_string() |> normalized()

  defp normalized(value) when is_binary(value) do
    value |> String.trim() |> String.downcase()
  end

  defp normalized(value), do: value |> to_string() |> normalized()

  defp contains?(value, fragment), do: String.contains?(normalized(value), fragment)

  defp bounded_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> String.slice(text, 0, @max_locator_value)
    end
  end

  defp bounded_text(nil), do: nil
  defp bounded_text(value) when is_atom(value), do: value |> Atom.to_string() |> bounded_text()
  defp bounded_text(_value), do: nil

  defp first_text(values) when is_list(values), do: Enum.find_value(values, &bounded_text/1)

  defp nested(map, keys) do
    Enum.reduce_while(keys, map, fn key, current ->
      case value(current, key) do
        nil -> {:halt, nil}
        next -> {:cont, next}
      end
    end)
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value(_map, _key), do: nil
end
