defmodule DevIDE.UAT.TierBTest do
  use DevIde.DataCase, async: false

  import Ecto.Query

  alias DevIDE.Previews.ControlObservation
  alias DevIDE.PreviewControl
  alias DevIDE.UAT.{FakeTransport, Run, TierB}

  setup do
    _ = PreviewControl.Registry.clear()
    :ok
  end

  test "builds a JSON-RPC 2.0 envelope" do
    assert TierB.envelope("preview_open", %{"surface" => "app"}, 7) == %{
             "jsonrpc" => "2.0",
             "id" => 7,
             "method" => "preview_open",
             "params" => %{"surface" => "app"}
           }
  end

  test "identity headers carry the forward-auth email (and nothing when blank)" do
    assert TierB.identity_headers("owner@example.com") == %{
             "X-Auth-Request-Email" => "owner@example.com"
           }

    assert TierB.identity_headers(nil) == %{}
    assert TierB.identity_headers("") == %{}
  end

  test "rpc/3 sends the envelope + identity headers through the transport" do
    FakeTransport.set_response({:ok, %{"result" => %{"ok" => true}}})

    assert {:ok, %{"result" => %{"ok" => true}}} =
             TierB.rpc("preview_navigate", %{"path" => "/cart"},
               transport: FakeTransport,
               identity: "owner@example.com",
               endpoint: "/run/devide/current.sock"
             )

    call = FakeTransport.last()
    assert call.endpoint == "/run/devide/current.sock"
    assert call.headers["X-Auth-Request-Email"] == "owner@example.com"
    assert call.request["method"] == "preview_navigate"
    assert call.request["params"] == %{"path" => "/cart"}
  end

  test "alert_for maps outcomes to the Tier B failure policy" do
    assert TierB.alert_for(:pass) == {:pass, :ok}
    assert TierB.alert_for(:fail) == {:fail, :regression_alert}
    assert TierB.alert_for(:drift) == {:drift, :needs_triage}
    assert TierB.alert_for(:errored) == {:errored, :infra_alert}
    assert TierB.alert_for(:anything_else) == {:errored, :infra_alert}
  end

  describe "run_criterion" do
    defp session_and_obs do
      {:ok, session} = PreviewControl.open_session(workspace(), "app")
      {:ok, _} = PreviewControl.navigate(session.id, "/")

      obs_id =
        Repo.one!(
          from o in ControlObservation, where: o.session_id == ^session.id, limit: 1, select: o.id
        )

      {session, obs_id}
    end

    defp workspace do
      %{
        id: "ws-preview",
        metadata: %{type: :v3, domain_base: "alice.devbox.example.com", ports: %{"app" => 10_100}}
      }
    end

    defp verdict(sid, obs_id, passed) do
      %{
        "passed" => passed,
        "criterion" => "c",
        "run_id" => "r",
        "session_id" => sid,
        "steps_taken" => [],
        "assertions" => [
          %{
            "desc" => "x",
            "result" => (passed && "pass") || "fail",
            "evidence" => %{"kind" => "url", "observation_id" => obs_id}
          }
        ]
      }
    end

    test "a grounded pass persists a tier_b run with :ok alert" do
      {session, obs_id} = session_and_obs()
      agent = fn _c, sid -> verdict(sid, obs_id, true) end

      assert {:pass, :ok, %Run{tier: :tier_b, outcome: :pass} = run} =
               TierB.run_criterion("c", session.id, %{scenario_id: "smoke"}, agent: agent)

      assert run.scenario_id == "smoke"
      assert run.target_instance == "/run/devide/current.sock"
      assert Repo.get(Run, run.id)
    end

    test "an ungrounded pass becomes :fail with a regression alert" do
      {session, _} = session_and_obs()
      agent = fn _c, sid -> verdict(sid, 999_999, true) end

      assert {:fail, :regression_alert, %Run{outcome: :fail}} =
               TierB.run_criterion("c", session.id, %{}, agent: agent)
    end

    test "an agent that raises becomes :errored with an infra alert (never silently green)" do
      {session, _} = session_and_obs()
      agent = fn _c, _sid -> raise "transport blew up" end

      assert {:errored, :infra_alert, %Run{outcome: :errored} = run} =
               TierB.run_criterion("c", session.id, %{}, agent: agent)

      assert run.verdict["exception"] =~ "transport blew up"
    end
  end
end
