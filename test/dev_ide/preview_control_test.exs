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
    assert session.metadata["surface_key"] == "app"
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

  # Global Application env: this module must stay async: false while any test
  # uses this helper — the put is visible to every concurrently running test.
  defp put_preview_default_headers(headers) do
    prev = Application.get_env(:dev_ide, :preview_default_headers)
    Application.put_env(:dev_ide, :preview_default_headers, headers)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:dev_ide, :preview_default_headers, prev),
        else: Application.delete_env(:dev_ide, :preview_default_headers)
    end)
  end

  test "configured preview_default_headers apply when the caller sends none" do
    put_preview_default_headers(%{"X-Auth-Request-Email" => "ops@example.com"})

    assert {:ok, session} = PreviewControl.open_localhost_session(@v3_workspace, 5173)
    assert session.metadata["default_headers"] == %{"X-Auth-Request-Email" => "ops@example.com"}
  end

  test "caller default_headers override configured preview_default_headers" do
    put_preview_default_headers(%{"X-Auth-Request-Email" => "ops@example.com"})

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

  test "workspace storage profile records a durable storage state path" do
    root = Path.join(System.tmp_dir!(), "devide-preview-storage-test")
    prev_root = Application.get_env(:dev_ide, :preview_storage_root)
    Application.put_env(:dev_ide, :preview_storage_root, root)

    on_exit(fn ->
      if prev_root,
        do: Application.put_env(:dev_ide, :preview_storage_root, prev_root),
        else: Application.delete_env(:dev_ide, :preview_storage_root)

      File.rm_rf(root)
    end)

    assert {:ok, session} =
             PreviewControl.open_localhost_session(@v3_workspace, 5173,
               storage_profile: :workspace
             )

    assert session.metadata["storage_profile"] == "workspace"
    assert session.metadata["storage_profile_key"] == "workspace"
    assert session.metadata["storage_state_path"] =~ root
    assert session.metadata["storage_state_path"] =~ ".storage"
    assert String.ends_with?(session.metadata["storage_state_path"], "workspace.json")
  end

  test "named storage profile is normalized and participates in session reuse" do
    assert {:ok, first} =
             PreviewControl.open_localhost_session(@v3_workspace, 5173,
               storage_profile: "profile",
               storage_profile_name: "Admin User"
             )

    assert first.metadata["storage_profile"] == "profile"
    assert first.metadata["storage_profile_name"] == "admin-user"

    assert {:ok, second} =
             PreviewControl.open_localhost_session(@v3_workspace, 5173,
               storage_profile: "profile",
               storage_profile_name: "Admin User"
             )

    assert second.id == first.id

    assert {:ok, third} =
             PreviewControl.open_localhost_session(@v3_workspace, 5173,
               storage_profile: "workspace"
             )

    assert third.id != first.id
  end

  test "named storage profile requires a profile name" do
    assert {:error, :missing_storage_profile_name} =
             PreviewControl.open_localhost_session(@v3_workspace, 5173,
               storage_profile: "profile"
             )
  end

  test "clear_storage records an audited action" do
    {:ok, session} = PreviewControl.open_session(@v3_workspace, "app")

    assert {:ok, storage} = PreviewControl.clear_storage(session.id)
    assert storage.local_storage == %{}
    assert storage.session_storage == %{}

    assert [%ControlAction{action: "clear_storage"}] =
             session.id
             |> actions_for()
             |> Enum.filter(&(&1.action == "clear_storage"))
  end

  test "open_localhost_session rejects disallowed ports" do
    assert {:error, %{error: :port_not_allowed, port: 9999, allowed_ports: allowed_ports}} =
             PreviewControl.open_localhost_session(@v3_workspace, 9999)

    assert 5173 in allowed_ports
    assert 10_100 in allowed_ports
  end

  test "navigate accepts cross-origin http URLs" do
    {:ok, session} = PreviewControl.open_session(@v3_workspace, "app")

    assert {:ok, result} = PreviewControl.navigate(session.id, "https://evil.example")
    assert result.url == "https://evil.example"

    assert {:ok, _} = PreviewControl.navigate(session.id, "/settings")
  end

  test "browser history actions update observations and audit trail" do
    {:ok, session} = PreviewControl.open_session(@v3_workspace, "app")

    assert {:ok, %{url: "https://alice.devbox.example.com:443/one"}} =
             PreviewControl.navigate(session.id, "/one")

    assert {:ok, %{url: "https://alice.devbox.example.com:443/two"}} =
             PreviewControl.navigate(session.id, "/two")

    assert {:ok, %{url: "https://alice.devbox.example.com:443/one"}} =
             PreviewControl.go_back(session.id)

    assert {:ok, %{url: "https://alice.devbox.example.com:443/two"}} =
             PreviewControl.go_forward(session.id)

    assert {:ok, %{url: "https://alice.devbox.example.com:443/two"}} =
             PreviewControl.reload(session.id)

    actions =
      session.id
      |> actions_for()
      |> Enum.map(& &1.action)

    assert "go_back" in actions
    assert "go_forward" in actions
    assert "reload" in actions
  end

  test "screenshot records an artifact observation" do
    {:ok, session} = PreviewControl.open_session(@v3_workspace, "app")
    assert {:ok, result} = PreviewControl.screenshot(session.id)
    assert result.artifact_path =~ ~r{^/preview-artifacts/ws-preview/\d+\.png$}
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

  test "navigate re-hydrates the runtime when the registry entry is gone (cross-instance)" do
    {:ok, session} = PreviewControl.open_session(@v3_workspace, "app")

    # Simulate the request landing on a different (or restarted) instance: the
    # in-memory runtime is gone but the ControlSession row stays status: :open.
    assert :ok = Registry.delete(session.id)
    assert Registry.get(session.id) == nil

    assert {:ok, result} = PreviewControl.navigate(session.id, "/rehydrated")
    assert result.url == "https://alice.devbox.example.com:443/rehydrated"
    assert Registry.get(session.id) != nil
  end

  test "observe re-hydrates the runtime when the registry entry is gone" do
    {:ok, session} = PreviewControl.open_session(@v3_workspace, "app")

    assert :ok = Registry.delete(session.id)
    assert Registry.get(session.id) == nil

    assert {:ok, observation} = PreviewControl.observe(session.id)
    assert observation.url == "https://alice.devbox.example.com"
    assert Registry.get(session.id) != nil
  end

  test "screenshot re-hydrates the runtime when the registry entry is gone" do
    {:ok, session} = PreviewControl.open_session(@v3_workspace, "app")

    assert :ok = Registry.delete(session.id)
    assert Registry.get(session.id) == nil

    assert {:ok, result} = PreviewControl.screenshot(session.id)
    assert result.artifact_path =~ ~r{^/preview-artifacts/ws-preview/\d+\.png$}
    assert Registry.get(session.id) != nil
  end

  test "navigate returns not_found for an unknown session id" do
    assert {:error, :not_found} = PreviewControl.navigate(999_999_999, "/nope")
  end

  test "navigate returns not_found for a closed session" do
    {:ok, session} = PreviewControl.open_session(@v3_workspace, "app")
    {:ok, _closed} = PreviewControl.close_session(session.id)
    assert Registry.get(session.id) == nil

    assert {:error, :not_found} = PreviewControl.navigate(session.id, "/nope")
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
