defmodule DevIDE.UAT.AuthorTest do
  use DevIDE.DataCase, async: false

  import Ecto.Query

  alias DevIDE.PreviewControl.Registry
  alias DevIDE.Previews.Control, as: PreviewControl
  alias DevIDE.Previews.ControlObservation
  alias DevIDE.UAT.{Author, Trace}

  @workspace %{
    id: "ws-preview",
    metadata: %{type: :v3, domain_base: "alice.devbox.example.com", ports: %{"app" => 10_100}}
  }

  setup do
    _ = Registry.clear()
    :ok
  end

  defp drive_session do
    {:ok, session} = PreviewControl.open_session(@workspace, "app")
    {:ok, _} = PreviewControl.navigate(session.id, "/")
    {:ok, _} = PreviewControl.click(session.id, %{selector: "button[type=submit]"})
    session
  end

  defp an_observation_id(session_id) do
    Repo.one!(
      from o in ControlObservation, where: o.session_id == ^session_id, limit: 1, select: o.id
    )
  end

  defp verdict(session_id, observation_id, passed) do
    %{
      "passed" => passed,
      "criterion" => "c",
      "run_id" => "r",
      "session_id" => session_id,
      "steps_taken" => [],
      "assertions" => [
        %{
          "desc" => "ok",
          "result" => (passed && "pass") || "fail",
          "evidence" => %{"kind" => "url", "observation_id" => observation_id}
        }
      ]
    }
  end

  test "validates a grounded pass and freezes a trace from the session" do
    session = drive_session()
    obs_id = an_observation_id(session.id)
    agent = fn _criterion, sid -> verdict(sid, obs_id, true) end

    assert {:ok, %{trace: %Trace{} = trace, verdict: v}} =
             Author.author(
               "c",
               session.id,
               %{id: "a", criterion: "c", target: %{"surface" => "app"}},
               agent: agent
             )

    assert v["passed"] == true
    assert Enum.map(trace.steps, & &1.kind) == [:navigate, :click]
  end

  test "rejects an ungrounded pass (observation from no session) — coerced to fail" do
    session = drive_session()
    agent = fn _c, sid -> verdict(sid, 999_999, true) end

    assert {:error, {:not_passed, v}} =
             Author.author("c", session.id, %{id: "a", criterion: "c"}, agent: agent)

    assert v["passed"] == false
  end

  test "rejects a malformed verdict at the shape layer" do
    session = drive_session()
    agent = fn _c, _sid -> %{"passed" => true} end

    assert {:error, {:invalid_verdict, _errors}} =
             Author.author("c", session.id, %{id: "a", criterion: "c"}, agent: agent)
  end
end
