defmodule Casein.Terminals.Osc133Test do
  use Casein.TestCase, async: true

  alias Casein.Terminals.Osc133

  test "parses OSC 133 and OSC 7 events while preserving ordinary data" do
    {tokens, state} =
      Osc133.new()
      |> Osc133.scan("before\e]7;file://host/tmp/work\a\e]133;A\a\e]133;B;mix test\aout")

    assert state.pending == ""

    assert tokens == [
             {:data, "before"},
             {:cwd, "/tmp/work"},
             {:prompt_start},
             {:command_start, "mix test"},
             {:data, "out"}
           ]
  end

  test "parses command finish status with ST termination" do
    {tokens, state} = Osc133.scan(Osc133.new(), "\e]133;D;2\e\\")

    assert state.pending == ""
    assert tokens == [{:command_end, 2}]
  end

  test "carries partial OSC sequences across chunks" do
    {tokens, state} = Osc133.scan(Osc133.new(), "a\e]133;B;echo")
    assert tokens == [{:data, "a"}]
    assert state.pending == "\e]133;B;echo"

    {tokens, state} = Osc133.scan(state, " ok\aoutput")

    assert state.pending == ""
    assert tokens == [{:command_start, "echo ok"}, {:data, "output"}]
  end

  test "preserves unrecognized OSC sequences as data" do
    raw = "\e]999;hello\a"
    {tokens, state} = Osc133.scan(Osc133.new(), raw)

    assert state.pending == ""
    assert tokens == [{:data, raw}]
  end

  test "parses cmd key payloads emitted by future shell integrations" do
    {tokens, _state} = Osc133.scan(Osc133.new(), "\e]133;C;pane=%2;cmd=echo%20ok\a")

    assert tokens == [{:output_start, "echo ok"}]
  end

  test "distinguishes command start (B) from output start (C)" do
    {tokens, _state} = Osc133.scan(Osc133.new(), "\e]133;B;mix test\a\e]133;C\a")

    assert tokens == [{:command_start, "mix test"}, {:output_start, nil}]
  end

  test "carries a chunk-final lone ESC so introducers split at the ESC parse" do
    {tokens, state} = Osc133.scan(Osc133.new(), "out\e")
    assert tokens == [{:data, "out"}]
    assert state.pending == "\e"

    {tokens, state} = Osc133.scan(state, "]133;A\aafter")

    assert state.pending == ""
    assert tokens == [{:prompt_start}, {:data, "after"}]
  end
end
