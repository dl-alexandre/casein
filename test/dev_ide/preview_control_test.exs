defmodule DevIDE.PreviewControlTest do
  use DevIde.DataCase, async: false

  import Ecto.Query

  alias DevIDE.PreviewControl
  alias DevIDE.PreviewControl.Registry
  alias DevIDE.Previews
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

  test "open_session broadcasts the preview for connected workspace viewers" do
    :ok = Phoenix.PubSub.subscribe(DevIde.PubSub, "preview:ws-preview")

    assert {:ok, session} = PreviewControl.open_session(@v3_workspace, "app")

    assert_receive {:preview_opened,
                    %{
                      workspace_id: "ws-preview",
                      preview_id: preview_id,
                      session_id: session_id,
                      preview_url: "https://alice.devbox.example.com",
                      current_url: "https://alice.devbox.example.com"
                    }}

    assert preview_id == session.preview_id
    assert session_id == session.id
  end

  test "open_localhost_session broadcasts preview_opened to folder viewer ids" do
    path = Path.join(System.tmp_dir!(), "dev_ide_preview_fanout")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)

    folder_id = DevIDE.Workspaces.Aliases.folder_id_for_path(path)
    :ok = Phoenix.PubSub.subscribe(DevIde.PubSub, "preview:#{folder_id}")

    workspace = %{
      id: folder_id,
      name: "dev_ide",
      path: path,
      metadata: %{attached_folder: true}
    }

    assert {:ok, _session} = PreviewControl.open_localhost_session(workspace, 5173)

    assert_receive {:preview_opened,
                    %{
                      workspace_id: ^folder_id,
                      preview_id: _preview_id,
                      session_id: _session_id,
                      preview_url: "http://localhost:5173/",
                      current_url: "http://localhost:5173/"
                    }}
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

    assert Enum.sort(Enum.map(actions, & &1.action)) == ["click", "type"]
  end

  test "open_localhost_session opens an allowed dev port" do
    assert {:ok, session} =
             PreviewControl.open_localhost_session(@v3_workspace, 5173,
               path: "/demo.html",
               actor_id: "agent-1",
               default_headers: %{"X-Auth-Request-Email" => "agent@example.com"}
             )

    assert session.surface == "localhost:5173"
    assert session.current_url == "http://localhost:5173/demo.html"
    assert session.metadata["default_headers"] == %{"X-Auth-Request-Email" => "agent@example.com"}
  end

  test "open_session falls back to detected surface when 'app' is not registered" do
    workspace = %{
      id: "ws-no-manager-surfaces",
      terminal_output: "Running at http://localhost:4000"
    }

    assert {:ok, session} = PreviewControl.open_session(workspace, "app")
    assert session.surface == "localhost:4000"
    assert session.current_url == "http://localhost:4000"
  end

  test "open_session still errors for explicitly named unknown surfaces" do
    workspace = %{
      id: "ws-no-manager-surfaces",
      terminal_output: "Running at http://localhost:4000"
    }

    assert {:error, :surface_not_found} = PreviewControl.open_session(workspace, "tidewave")
  end

  test "configured preview_default_headers apply when the caller sends none" do
    prev = Application.get_env(:dev_ide, :preview_default_headers)

    Application.put_env(:dev_ide, :preview_default_headers, %{
      "X-Auth-Request-Email" => "ops@example.com"
    })

    on_exit(fn ->
      if prev,
        do: Application.put_env(:dev_ide, :preview_default_headers, prev),
        else: Application.delete_env(:dev_ide, :preview_default_headers)
    end)

    assert {:ok, session} = PreviewControl.open_localhost_session(@v3_workspace, 5173)
    assert session.metadata["default_headers"] == %{"X-Auth-Request-Email" => "ops@example.com"}
  end

  test "caller default_headers override configured preview_default_headers" do
    prev = Application.get_env(:dev_ide, :preview_default_headers)

    Application.put_env(:dev_ide, :preview_default_headers, %{
      "X-Auth-Request-Email" => "ops@example.com"
    })

    on_exit(fn ->
      if prev,
        do: Application.put_env(:dev_ide, :preview_default_headers, prev),
        else: Application.delete_env(:dev_ide, :preview_default_headers)
    end)

    assert {:ok, session} =
             PreviewControl.open_localhost_session(@v3_workspace, 5173,
               default_headers: %{"X-Auth-Request-Email" => "agent@example.com"}
             )

    assert session.metadata["default_headers"] == %{"X-Auth-Request-Email" => "agent@example.com"}
  end

  test "open_localhost_session reuses preview and compatible control session across routes" do
    assert {:ok, first} =
             PreviewControl.open_localhost_session(@v3_workspace, 5173,
               path: "/one",
               actor_id: "agent-1"
             )

    assert {:ok, second} =
             PreviewControl.open_localhost_session(@v3_workspace, 5173,
               path: "/two",
               actor_id: "agent-1"
             )

    assert second.id == first.id
    assert second.preview_id == first.preview_id
    assert second.current_url == "http://localhost:5173/two"
    assert [_] = Previews.list_for_workspace("ws-preview")
  end

  test "new_control_session opens a fresh runtime on the same preview" do
    assert {:ok, first} =
             PreviewControl.open_localhost_session(@v3_workspace, 5173,
               path: "/one",
               actor_id: "agent-1"
             )

    assert {:ok, second} =
             PreviewControl.open_localhost_session(@v3_workspace, 5173,
               path: "/two",
               actor_id: "agent-1",
               new_control_session: true
             )

    assert second.id != first.id
    assert second.preview_id == first.preview_id
    assert second.current_url == "http://localhost:5173/two"
    assert [_] = Previews.list_for_workspace("ws-preview")
  end

  test "open_localhost_session rejects disallowed ports" do
    assert {:error, %{error: :port_not_allowed, port: 9999, allowed_ports: allowed_ports}} =
             PreviewControl.open_localhost_session(@v3_workspace, 9999)

    assert 5173 in allowed_ports
    assert 10_100 in allowed_ports
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

  test "get_open_session_for_preview returns session when ids match and status is open" do
    {:ok, session} = PreviewControl.open_session(@v3_workspace, "app")

    result = PreviewControl.get_open_session_for_preview(session.id, session.preview_id)
    assert result != nil
    assert result.id == session.id
    assert result.preview_id == session.preview_id
  end

  test "get_open_session_for_preview returns nil for mismatched preview_id" do
    {:ok, session} = PreviewControl.open_session(@v3_workspace, "app")

    assert nil ==
             PreviewControl.get_open_session_for_preview(session.id, session.preview_id + 9999)
  end

  test "get_open_session_for_preview returns nil after session is closed" do
    {:ok, session} = PreviewControl.open_session(@v3_workspace, "app")

    assert result = PreviewControl.get_open_session_for_preview(session.id, session.preview_id)
    assert result != nil

    {:ok, _closed} = PreviewControl.close_session(session.id)
    assert nil == PreviewControl.get_open_session_for_preview(session.id, session.preview_id)
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
