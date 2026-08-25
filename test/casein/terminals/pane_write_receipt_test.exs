defmodule Casein.Terminals.PaneWriteReceiptTest do
  use ExUnit.Case, async: false

  alias Casein.Terminals.PaneWriteReceipt
  alias TmuxCtl.Test.FakeState

  @session "casein_alpha_receipt"
  @pane "%9"

  setup do
    previous = %{
      tmux_adapter: Application.get_env(:casein, :tmux_adapter),
      fake_tmux_scrollback: FakeState.get(:fake_tmux_scrollback),
      fake_tmux_test_pid: FakeState.get(:fake_tmux_test_pid)
    }

    FakeState.put(:fake_tmux_test_pid, self())
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    FakeState.delete(:fake_tmux_scrollback)

    on_exit(fn ->
      FakeState.restore(:fake_tmux_scrollback, previous.fake_tmux_scrollback)
      FakeState.restore(:fake_tmux_test_pid, previous.fake_tmux_test_pid)

      if previous.tmux_adapter,
        do: Application.put_env(:casein, :tmux_adapter, previous.tmux_adapter),
        else: Application.delete_env(:casein, :tmux_adapter)
    end)

    :ok
  end

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

  test "receipt classifies a faint suggested prompt as placeholder" do
    FakeState.put(:fake_tmux_scrollback, %{
      {"casein_ws_main", "%3"} =>
        "❯  \e[2mswitch gh to my account mbaldin\e[22m\n  1.0K · claude-sonnet · ⏎ send\n"
    })

    payload = PaneWriteReceipt.attach(%{status: "sent"}, "casein_ws_main", "%3", "hello")

    assert payload.receipt.input_buffer == %{has_content: false, source: "placeholder"}
    assert payload.receipt.observed_excerpt =~ "switch gh to my account mbaldin"
    refute payload.receipt.observed_excerpt =~ "\e[2m"
  end

  test "receipt reports unknown when composer text cannot be classified" do
    FakeState.put(:fake_tmux_scrollback, %{
      {"casein_ws_main", "%3"} => "❯  switch gh to my account mbaldin\n"
    })

    payload = PaneWriteReceipt.attach(%{status: "sent"}, "casein_ws_main", "%3", "hello")

    assert payload.receipt.input_buffer == %{has_content: "unknown", source: "unknown"}
  end
end
