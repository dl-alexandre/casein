defmodule DevIDE.UAT.FreezeTest do
  use DevIde.DataCase, async: false

  alias DevIDE.PreviewControl
  alias DevIDE.UAT.{Freeze, Replay, Run, Step, Trace}

  @workspace %{
    id: "ws-preview",
    metadata: %{
      type: :v3,
      domain_base: "alice.devbox.example.com",
      ports: %{"app" => 10_100}
    }
  }

  setup do
    _ = PreviewControl.Registry.clear()
    :ok
  end

  test "freezes a driven session into a replayable trace with provenance" do
    {:ok, session} = PreviewControl.open_session(@workspace, "app")
    {:ok, _} = PreviewControl.navigate(session.id, "/login")
    {:ok, _} = PreviewControl.type(session.id, "input[name=q]", "hello", %{})
    {:ok, _} = PreviewControl.click(session.id, %{selector: "button[type=submit]"})

    assert {:ok, %Trace{} = trace} =
             Freeze.from_session(session.id, %{
               id: "frozen",
               criterion: "search submits",
               target: %{"surface" => "app"}
             })

    # The action spine is reconstructed in order; observe/screenshot are skipped.
    assert Enum.map(trace.steps, & &1.kind) == [:navigate, :type, :click]

    # The click matcher is durable: selector + the role/name observed at author time.
    click = List.last(trace.steps)
    assert click.match["selector"] == "button[type=submit]"
    assert click.match["role"] == "button"
    assert click.match["name"] == "Submit"

    # Provenance back-references the authoring run.
    assert is_integer(click.from["action_id"])
    assert trace.provenance["authored_by_session"] == session.id

    # And it survives the on-disk JSON form.
    assert Trace.from_json(Trace.to_json(trace)) == trace
  end

  test "a frozen action spine replays cleanly against the same surface" do
    {:ok, session} = PreviewControl.open_session(@workspace, "app")
    {:ok, _} = PreviewControl.navigate(session.id, "/")
    {:ok, _} = PreviewControl.click(session.id, %{selector: "button[type=submit]"})

    {:ok, trace} =
      Freeze.from_session(session.id, %{
        id: "replayable",
        criterion: "c",
        target: %{"surface" => "app"}
      })

    PreviewControl.close_session(session.id)

    # The harness adds assertions from the criterion; here we add one directly.
    trace = %{
      trace
      | steps: trace.steps ++ [%Step{kind: :assert_no_errors, console: true, network: true}]
    }

    assert {:ok, %Run{outcome: :pass}} = Replay.run(trace, @workspace)
  end

  test "skips non-replayable actions and requires id + criterion" do
    {:ok, session} = PreviewControl.open_session(@workspace, "app")
    {:ok, _} = PreviewControl.observe(session.id)

    assert {:ok, %Trace{steps: []}} = Freeze.from_session(session.id, %{id: "x", criterion: "c"})
    assert {:error, {:missing, :id}} = Freeze.from_session(session.id, %{criterion: "c"})
    assert {:error, {:missing, :criterion}} = Freeze.from_session(session.id, %{id: "x"})
  end
end
