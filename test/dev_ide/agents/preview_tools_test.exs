defmodule DevIDE.Agents.PreviewToolsTest do
  use DevIde.DataCase, async: false

  alias DevIDE.Agents.PreviewTools
  alias DevIDE.PreviewControl.Registry
  alias DevIDE.Previews.ControlObservation
  alias DevIde.Repo

  @v3_workspace %{
    id: "ws-tools",
    metadata: %{
      type: :v3,
      domain_base: "alice.devbox.example.com",
      ports: %{"app" => 10_100}
    }
  }

  setup do
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    _ = Registry.clear()

    on_exit(fn ->
      if is_nil(prev_root),
        do: Application.delete_env(:dev_ide, :workspaces_root),
        else: Application.put_env(:dev_ide, :workspaces_root, prev_root)
    end)

    :ok
  end

  test "definitions exposes narrow agent preview tools" do
    names = PreviewTools.definitions() |> Enum.map(& &1.name)
    assert "preview_resolve_workspace" in names
    assert "preview_surfaces" in names
    assert "preview_open_current_workspace" in names
    assert "preview_open_app" in names
    assert "preview_open_localhost" in names
    assert "preview_navigate" in names
    assert "preview_observe" in names
    assert "preview_observe_live" in names
    assert "preview_screenshot" in names
    assert "preview_close" in names
    assert "preview_get_storage" in names
    assert "preview_reload_iframe" in names
    assert "devide_reload_page" in names
  end

  test "reload tools broadcast workspace browser control requests" do
    :ok = Phoenix.PubSub.subscribe(DevIde.PubSub, "workspace_browser:ws-tools")

    assert {:ok,
            %{
              status: "queued",
              action: "reload_preview_iframe",
              workspace_id: "ws-tools",
              request_id: iframe_request_id
            }} =
             PreviewTools.invoke("preview_reload_iframe", @v3_workspace, %{
               "actor_id" => "agent-1",
               "reason" => "stale preview"
             })

    assert_receive {:browser_control,
                    %{
                      "action" => "reload_preview_iframe",
                      "actor_id" => "agent-1",
                      "reason" => "stale preview",
                      "request_id" => ^iframe_request_id,
                      "workspace_id" => "ws-tools"
                    }}

    assert {:ok,
            %{
              status: "queued",
              action: "reload_page",
              workspace_id: "ws-tools",
              request_id: page_request_id
            }} =
             PreviewTools.invoke("devide_reload_page", @v3_workspace, %{"actor_id" => "agent-1"})

    assert_receive {:browser_control,
                    %{
                      "action" => "reload_page",
                      "actor_id" => "agent-1",
                      "request_id" => ^page_request_id,
                      "workspace_id" => "ws-tools"
                    }}
  end

  test "invoke surfaces lists manager and terminal-detected ports" do
    ws =
      Map.update!(@v3_workspace, :metadata, fn metadata ->
        Map.put(metadata, :terminal_output, "Serving at http://localhost:8765/")
      end)

    assert {:ok, %{surfaces: surfaces}} = PreviewTools.invoke("preview_surfaces", ws, %{})
    names = Enum.map(surfaces, & &1.name)
    assert "app" in names
    assert "localhost:8765" in names
  end

  test "invoke open_localhost opens a common dev port" do
    assert {:ok, %{session_id: session_id, current_url: url}} =
             PreviewTools.invoke("preview_open_localhost", @v3_workspace, %{
               "port" => 5173,
               "path" => "/index.html",
               "actor_id" => "agent-1"
             })

    assert is_integer(session_id)
    assert url == "http://localhost:5173/index.html"
  end

  test "invoke open_localhost rejects disallowed ports" do
    assert {:error, %{error: :port_not_allowed, port: 9999, allowed_ports: allowed_ports}} =
             PreviewTools.invoke("preview_open_localhost", @v3_workspace, %{"port" => 9999})

    assert 5173 in allowed_ports
  end

  test "resolve_workspace returns guidance for missing references" do
    assert {:error,
            %{
              error: :missing_workspace_reference,
              folder_id_format: "folder:<base64url-absolute-path>"
            }} =
             PreviewTools.invoke("preview_resolve_workspace", %{}, %{})
  end

  test "resolve_workspace attaches an allowed folder path" do
    root =
      Path.join(System.tmp_dir!(), "preview-tools-root-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "demo")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    Application.put_env(:dev_ide, :workspaces_root, root)

    assert {:ok, %{workspace_id: "folder:" <> _encoded, path: ^workspace}} =
             PreviewTools.invoke("preview_resolve_workspace", %{}, %{
               "workspace_path" => workspace
             })
  end

  test "invoke navigate moves within allowed origin" do
    assert {:ok, %{session_id: session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{"actor_id" => "agent-1"})

    assert {:ok, observation} =
             PreviewTools.invoke("preview_navigate", @v3_workspace, %{
               "session_id" => session_id,
               "path" => "/settings"
             })

    assert observation.url =~ "/settings"
  end

  test "invoke opens app preview and observes it" do
    assert {:ok, %{session_id: session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1"
             })

    assert {:ok, observation} =
             PreviewTools.invoke("preview_observe", @v3_workspace, %{"session_id" => session_id})

    assert observation.url =~ "alice.devbox.example.com"
  end

  test "invoke observes live browser state" do
    assert {:ok, %{session_id: session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1"
             })

    assert {:ok, observation} =
             PreviewTools.invoke("preview_observe_live", @v3_workspace, %{
               "session_id" => session_id
             })

    assert observation.url =~ "alice.devbox.example.com"
    assert is_map(observation.dom_summary)
  end

  test "invoke returns preview origin storage" do
    assert {:ok, %{session_id: session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1"
             })

    assert {:ok,
            %{
              local_storage: %{},
              session_storage: %{},
              url: url
            }} =
             PreviewTools.invoke("preview_get_storage", @v3_workspace, %{
               "session_id" => session_id
             })

    assert url =~ "alice.devbox.example.com"
  end

  test "invoke report_errors returns console and network observations" do
    assert {:ok, %{session_id: session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1"
             })

    insert_observation!(session_id, "console_errors", %{
      "errors" => [%{"type" => "console", "text" => "boom"}]
    })

    insert_observation!(session_id, "network_errors", %{
      "errors" => [%{"type" => "response", "status" => 500}]
    })

    assert {:ok,
            %{
              console_errors: [%{"type" => "console", "text" => "boom"}],
              network_errors: [%{"type" => "response", "status" => 500}]
            }} =
             PreviewTools.invoke("preview_report_errors", @v3_workspace, %{
               "session_id" => session_id
             })
  end

  test "invoke closes an open preview session" do
    assert {:ok, %{session_id: session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1"
             })

    assert {:ok, %{session_id: ^session_id, status: :closed}} =
             PreviewTools.invoke("preview_close", @v3_workspace, %{"session_id" => session_id})

    assert {:error, :not_found} =
             PreviewTools.invoke("preview_observe", @v3_workspace, %{"session_id" => session_id})
  end

  test "list_surfaces returns manager surfaces for planning" do
    surfaces = PreviewTools.list_surfaces(@v3_workspace)
    assert Enum.any?(surfaces, &(&1.name == "app"))
  end

  defp insert_observation!(session_id, kind, data) do
    %ControlObservation{}
    |> ControlObservation.changeset(%{session_id: session_id, kind: kind, data: data})
    |> Repo.insert!()
  end
end
