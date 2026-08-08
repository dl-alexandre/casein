defmodule Casein.Terminals.NextPrompt.Delivery do
  @moduledoc """
  Injects a staged operator prompt into its agent pane and records what
  happened.

  Transport is `Casein.Terminals.PaneSubmit`, which pastes through the normal
  prompt-chunking path and then *confirms* the submit landed. The pane label is
  deliberately not rewritten (`name_pane: false`): a sticky prompt is a nudge
  into work already in progress, and letting "also rebase first" rename the pane
  loses the name of the task it is actually doing.

  Every terminal outcome — delivered, failed, dropped — writes an audit row, so
  a message that never reached its agent is answerable after the fact instead of
  vanishing.
  """

  alias Casein.Agents.Activity
  alias Casein.Audit
  alias Casein.Export.Sanitizer
  alias Casein.Terminals.PaneSubmit

  @excerpt_bytes 512

  @doc """
  Deliver `entry` into its pane. `trigger` is the state edge that released it
  (`:immediate` when the pane was already in the requested state).
  """
  @spec deliver(map(), atom()) :: {:ok, map()} | {:error, map()}
  def deliver(entry, trigger) do
    opts = [
      workspace_id: entry.workspace_id,
      actor_id: entry.set_by || "next_prompt",
      name_pane: false,
      name_session: false,
      name_window: false
    ]

    case PaneSubmit.deliver(entry.tmux_session, entry.pane_id, entry.text, opts) do
      {:ok, result} ->
        record(entry, trigger, "delivered", :ok, result)
        {:ok, result}

      {:error, error} ->
        record(entry, trigger, "failed", :error, error)
        {:error, error}
    end
  end

  @doc "Record a pending prompt that was discarded without being delivered."
  @spec record_dropped(map(), atom()) :: :ok
  def record_dropped(entry, reason) do
    record(entry, reason, "dropped", :error, %{})
  end

  defp record(entry, trigger, outcome, status, result)
       when is_binary(entry.workspace_id) do
    metadata =
      %{
        "coalesce_key" => entry.coalesce_key,
        "confirmation" => stringify(Map.get(result, :confirmation)),
        "delivery" => stringify(Map.get(result, :delivery)),
        "deliver_when" => Atom.to_string(entry.deliver_when),
        "enter_presses" => Map.get(result, :enter_presses),
        "attempts" => entry.attempts,
        "agent_session_id" => entry.agent_session_id,
        "pane" => entry.pane_id,
        "prompt_excerpt" => excerpt(entry.text),
        "reason" => stringify(Map.get(result, :error)),
        "tmux_session" => entry.tmux_session,
        "trigger" => stringify(trigger)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    Audit.emit!(%{
      workspace_id: entry.workspace_id,
      actor_id: entry.set_by || "next_prompt",
      action: "agent.next_prompt_" <> outcome,
      source: "next_prompt",
      target_type: "tmux_pane",
      target_ref: entry.pane_id,
      metadata: metadata
    })

    Activity.record(%{
      workspace_id: entry.workspace_id,
      source: :terminal_mcp,
      tool: "terminal_set_next_prompt",
      summary: summary(entry, outcome, trigger),
      metadata: metadata,
      status: status
    })

    :ok
  end

  # Without a workspace there is nowhere to file the row; the injection itself
  # still happened and the caller still gets its result.
  defp record(_entry, _trigger, _outcome, _status, _result), do: :ok

  defp summary(entry, outcome, trigger) do
    "next prompt #{outcome} · pane=#{entry.pane_id} when=#{entry.deliver_when} " <>
      "trigger=#{stringify(trigger)}"
  end

  defp excerpt(text) when is_binary(text) do
    text |> Sanitizer.redact_text() |> String.slice(0, @excerpt_bytes)
  end

  defp excerpt(_text), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value, limit: 20, printable_limit: 200)
end
