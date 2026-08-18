defmodule Casein.Terminals.PaneWriteReceipt do
  @moduledoc """
  Proof that a pane write landed in the target pane.

  `terminal_say` has an inbox, so the sender can tell "I sent it" from "they
  have it". Keystroke writes only had `status: "sent"`. This receipt captures
  the pane tail after the write so those two states are distinguishable.
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
      observed: excerpt_contains?(excerpt, written),
      delivered_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    payload
    |> Map.put(:write_id, write_id)
    |> Map.put(:receipt, receipt)
  end

  def attach(payload, _session, _pane_id, _written), do: payload

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

  defp excerpt_contains?(excerpt, written)
       when is_binary(excerpt) and is_binary(written) and written != "" do
    String.contains?(excerpt, String.trim(written))
  end

  defp excerpt_contains?(_excerpt, _written), do: false
end
