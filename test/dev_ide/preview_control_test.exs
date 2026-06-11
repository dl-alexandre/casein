defmodule DevIDE.PreviewControlTest do
  use DevIde.DataCase, async: false

  import Ecto.Query

  alias DevIDE.PreviewControl
  alias DevIDE.PreviewControl.Registry
  alias DevIDE.Previews.{ControlAction, ControlObservation}
  alias DevIde.Repo

  @v3_workspace %{
    id: "ws-preview",
    metadata: %{
      type: :v3,
      domain_base: "alice.devbox.example.com",
      ports: %{"app" => 10_100, "tidewave" => 11_003}
    }
  }

  setup do
    _ = Registry.clear()
    :ok
  end

  test "open_session creates preview, session, and runtime state" do
    assert {:ok, session} =
             PreviewControl.open_session(@v3_workspace, "app", actor_id: "agent-1")

    assert session.workspace_id == "ws-preview"
    assert session.surface == "app"
    assert session.current_url == "https://alice.devbox.example.com"
    assert session.actor_id == "agent-1"
    assert {:ok, _entry} = {:ok, Registry.get(session.id)}
  end

  test "observe returns simulated DOM summary via memory adapter" do
    {:ok, session} = PreviewControl.open_session(@v3_workspace, "app")
    assert {:ok, observation} = PreviewControl.observe(session.id)
    assert observation.url == "https://alice.devbox.example.com"
    assert is_list(observation.dom_summary.selectors)
  end

  test "observe_live returns browser-backed observation via memory adapter" do
    {:ok, session} = PreviewControl.open_session(@v3_workspace, "app")
    assert {:ok, observation} = PreviewControl.observe_live(session.id)
    assert observation.url == "https://alice.devbox.example.com"
    assert is_list(observation.dom_summary.selectors)

    assert [%ControlAction{action: "observe_live"}] = actions_for(session.id)
  end

  test "click and type update audit trail" do
    {:ok, session} = PreviewControl.open_session(@v3_workspace, "app", actor_id: "agent-1")
    assert {:ok, _} = PreviewControl.click(session.id, %{selector: "button[type=submit]"})
    assert {:ok, _} = PreviewControl.type(session.id, "#app", "hello")

    actions =
      Repo.all(
        from a in ControlAction,
          where: a.session_id == ^session.id,
          order_by: [asc: a.inserted_at]
      )

    assert Enum.map(actions, & &1.action) == ["click", "type"]
  end

  test "open_localhost_session opens an allowed dev port" do
    assert {:ok, session} =
             PreviewControl.open_localhost_session(@v3_workspace, 5173,
               path: "/demo.html",
               actor_id: "agent-1"
             )

    assert session.surface == "localhost:5173"
    assert session.current_url == "http://localhost:5173/demo.html"
  end

  test "open_localhost_session rejects disallowed ports" do
    assert {:error, :port_not_allowed} =
             PreviewControl.open_localhost_session(@v3_workspace, 9999)
  end

  test "navigate rejects cross-origin URLs" do
    {:ok, session} = PreviewControl.open_session(@v3_workspace, "app")

    assert {:error, :origin_not_allowed} =
             PreviewControl.navigate(session.id, "https://evil.example")

    assert {:ok, _} = PreviewControl.navigate(session.id, "/settings")
  end

  test "screenshot records an artifact observation" do
    {:ok, session} = PreviewControl.open_session(@v3_workspace, "app")
    assert {:ok, result} = PreviewControl.screenshot(session.id)
    assert result.artifact_path =~ "memory://screenshot/"
  end

  test "get_storage returns and records storage for the preview origin" do
    {:ok, session} = PreviewControl.open_session(@v3_workspace, "app")

    assert {:ok,
            %{
              url: "https://alice.devbox.example.com",
              local_storage: %{},
              session_storage: %{}
            }} = PreviewControl.get_storage(session.id)

    assert [%ControlAction{action: "get_storage"}] = actions_for(session.id)

    assert %ControlObservation{kind: "storage", data: data} =
             Repo.get_by(ControlObservation, session_id: session.id, kind: "storage")

    assert data["local_storage"] == %{}
    assert data["session_storage"] == %{}
  end

  test "latest_errors returns the latest console and network observations" do
    {:ok, session} = PreviewControl.open_session(@v3_workspace, "app")

    insert_observation!(session.id, "console_errors", %{"errors" => [%{"text" => "old"}]})
    insert_observation!(session.id, "console_errors", %{"errors" => [%{"text" => "new"}]})
    insert_observation!(session.id, "network_errors", %{"errors" => [%{"status" => 500}]})

    assert PreviewControl.latest_errors(session.id) == %{
             console_errors: [%{"text" => "new"}],
             network_errors: [%{"status" => 500}]
           }
  end

  test "close_session clears runtime registry entry" do
    {:ok, session} = PreviewControl.open_session(@v3_workspace, "app")
    assert {:ok, %{} = closed} = PreviewControl.close_session(session.id)
    assert closed.status == :closed
    assert Registry.get(session.id) == nil
  end

  defp insert_observation!(session_id, kind, data) do
    %ControlObservation{}
    |> ControlObservation.changeset(%{session_id: session_id, kind: kind, data: data})
    |> Repo.insert!()
  end

  defp actions_for(session_id) do
    Repo.all(
      from a in ControlAction,
        where: a.session_id == ^session_id,
        order_by: [asc: a.inserted_at]
    )
  end
end
