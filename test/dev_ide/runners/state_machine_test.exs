defmodule DevIDE.Runners.StateMachineTest do
  use ExUnit.Case, async: true

  alias DevIDE.Runners.StateMachine

  test "runner assignment state machine accepts only v1 transitions" do
    assert StateMachine.statuses() ==
             ~w(queued claimed running succeeded failed expired abandoned)

    assert {:ok, "claimed"} = StateMachine.transition("queued", :claim)
    assert {:ok, "running"} = StateMachine.transition("claimed", :start)
    assert {:ok, "succeeded"} = StateMachine.transition("running", :succeed)
    assert {:ok, "failed"} = StateMachine.transition("running", :fail)
    assert {:ok, "expired"} = StateMachine.transition("claimed", :expire)
    assert {:ok, "abandoned"} = StateMachine.transition("claimed", :abandon)

    assert {:error, :invalid_transition} = StateMachine.transition("queued", :succeed)
    assert {:error, :assignment_terminal} = StateMachine.transition("succeeded", :fail)
  end
end
