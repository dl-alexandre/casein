defmodule Casein.Terminals.PaneWriteReceiptTest do
  use ExUnit.Case, async: false

  alias Casein.Terminals.PaneWriteReceipt
  alias TmuxCtl.Test.FakeState

  @session "casein_alpha_receipt"
  @pane "%9"

  setup do
    prev_test_pid = FakeState.get(:fake_tmux_test_pid)
    prev_adapter = Application.get_env(:casein, :tmux_adapter)

    FakeState.put(:fake_tmux_test_pid, self())
    Application.put_env(:casein, :tmux_adapter, TmuxCtl.Test.FakeAdapter)

    on_exit(fn ->
      FakeState.restore(:fake_tmux_test_pid, prev_test_pid)
      restore_app_env(:tmux_adapter, prev_adapter)
    end)

    :ok
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:casein, key)
  defp restore_app_env(key, value), do: Application.put_env(:casein, key, value)

  test "observed is true when the excerpt contains the written text" do
    FakeState.put(:fake_tmux_scrollback, %{
      {@session, @pane} => "hello world\nmix test"
    })

    payload = PaneWriteReceipt.attach(%{status: "sent"}, @session, @pane, "mix test")

    assert payload.receipt.observed == true
    assert payload.receipt.observed_excerpt =~ "mix test"
    assert payload.write_id == payload.receipt.write_id
  end

  test "observed is unknown when the excerpt does not contain the written text" do
    FakeState.put(:fake_tmux_scrollback, %{
      {@session, @pane} => "> idle composer"
    })

    payload = PaneWriteReceipt.attach(%{status: "sent"}, @session, @pane, "mix test")

    assert payload.receipt.observed == "unknown"
  end

  test "observed is unknown when capture returns nothing" do
    FakeState.put(:fake_tmux_scrollback, %{})

    payload = PaneWriteReceipt.attach(%{status: "sent"}, @session, @pane, "mix test")

    assert payload.receipt.observed == "unknown"
  end

  test "promote_observed becomes true only after a delivered confirmation" do
    payload = %{receipt: %{observed: "unknown"}}

    assert PaneWriteReceipt.promote_observed(payload, :delivered).receipt.observed == true

    assert PaneWriteReceipt.promote_observed(payload, :not_confirmed).receipt.observed ==
             "unknown"

    assert PaneWriteReceipt.promote_observed(payload, :uncertain).receipt.observed == "unknown"
  end
end
