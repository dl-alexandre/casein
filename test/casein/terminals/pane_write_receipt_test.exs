defmodule Casein.Terminals.PaneWriteReceiptTest do
  use ExUnit.Case, async: false

  alias Casein.Terminals.PaneWriteReceipt

  setup do
    previous = %{
      tmux_adapter: Application.get_env(:casein, :tmux_adapter),
      fake_tmux_scrollback: TmuxCtl.Test.FakeState.get(:fake_tmux_scrollback)
    }

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    TmuxCtl.Test.FakeState.delete(:fake_tmux_scrollback)

    on_exit(fn ->
      TmuxCtl.Test.FakeState.restore(:fake_tmux_scrollback, previous.fake_tmux_scrollback)

      if previous.tmux_adapter,
        do: Application.put_env(:casein, :tmux_adapter, previous.tmux_adapter),
        else: Application.delete_env(:casein, :tmux_adapter)
    end)

    :ok
  end

  test "receipt classifies a faint suggested prompt as placeholder" do
    TmuxCtl.Test.FakeState.put(:fake_tmux_scrollback, %{
      {"casein_ws_main", "%3"} =>
        "❯  \e[2mswitch gh to my account mbaldin\e[22m\n  1.0K · claude-sonnet · ⏎ send\n"
    })

    payload = PaneWriteReceipt.attach(%{status: "sent"}, "casein_ws_main", "%3", "hello")

    assert payload.receipt.input_buffer == %{has_content: false, source: "placeholder"}
    assert payload.receipt.observed_excerpt =~ "switch gh to my account mbaldin"
    refute payload.receipt.observed_excerpt =~ "\e[2m"
  end

  test "receipt reports unknown when composer text cannot be classified" do
    TmuxCtl.Test.FakeState.put(:fake_tmux_scrollback, %{
      {"casein_ws_main", "%3"} => "❯  switch gh to my account mbaldin\n"
    })

    payload = PaneWriteReceipt.attach(%{status: "sent"}, "casein_ws_main", "%3", "hello")

    assert payload.receipt.input_buffer == %{has_content: "unknown", source: "unknown"}
  end
end
