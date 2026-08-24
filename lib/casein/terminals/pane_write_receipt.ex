defmodule Casein.Terminals.PaneWriteReceipt do
  @moduledoc """
  Proof that a pane write landed in the target pane.

  `terminal_say` has an inbox, so the sender can tell "I sent it" from "they
  have it". Keystroke writes only had `status: "sent"`. This receipt captures
  the pane tail after the write so those two states are distinguishable.

  `observed` is tri-state and must stay honest:

    * `true` — the written bytes were seen in the pane tail, or a later
      `PaneSubmit` confirmation promoted this receipt after the agent consumed
      the input (`promote_observed/2`)
    * `false` — reserved for a write Casein knows did not land
    * `"unknown"` — capture failed, the TUI consumed the input before the
      excerpt was taken, or the written keys do not echo. A constant `false`
      here is not evidence of failure.

  Confirming that an *agent consumed* the input is `PaneSubmit`'s job
  (`delivery` / `confirmation` / `submitted`).
  """

  alias Casein.Terminals

  @excerpt_lines 12

  @spec attach(map(), String.t(), String.t(), term()) :: map()
  def attach(payload, session, pane_id, written) when is_map(payload) do
    excerpt = observe(session, pane_id)
    write_id = Ecto.UUID.generate()

    receipt = %{
      write_id: write_id,
      session: session,
      pane_id: pane_id,
      observed_excerpt: excerpt,
      observed: excerpt_status(excerpt, written),
      delivered_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    payload
    |> Map.put(:write_id, write_id)
    |> Map.put(:receipt, receipt)
  end

  def attach(payload, _session, _pane_id, _written), do: payload

  @doc """
  Mark `receipt.observed` true once submit confirmation proved consumption.

  Screen-substring observation cannot see a TUI that already ate the input.
  When `delivery` is `:delivered`, the write is no longer undecidable.
  """
  @spec promote_observed(map(), atom() | String.t()) :: map()
  def promote_observed(%{receipt: receipt} = payload, delivery)
      when is_map(receipt) and delivery in [:delivered, "delivered"] do
    put_in(payload, [:receipt, :observed], true)
  end

  def promote_observed(payload, _delivery), do: payload

  defp observe(session, pane_id)
       when is_binary(session) and is_binary(pane_id) and pane_id != "" do
    Terminals.tmux_adapter().capture_scrollback(session,
      target: pane_id,
      ansi: false,
      lines: @excerpt_lines
    )
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp observe(_session, _pane_id), do: nil

  defp excerpt_status(excerpt, written)
       when is_binary(excerpt) and is_binary(written) and written != "" do
    if String.contains?(excerpt, String.trim(written)), do: true, else: "unknown"
  end

  defp excerpt_status(_excerpt, _written), do: "unknown"
end
