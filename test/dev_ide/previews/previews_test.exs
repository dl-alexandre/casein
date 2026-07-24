defmodule Casein.PreviewsTest do
  use Casein.DataCase, async: false

  alias Casein.Previews
  alias Casein.Previews.Preview

  @workspace %{id: "ws-1"}

  setup do
    prev_app_url = Application.get_env(:casein, :preview_app_url)
    prev_loopback = Application.get_env(:casein, :preview_loopback_port)

    on_exit(fn ->
      restore_env(:preview_app_url, prev_app_url)
      restore_env(:preview_loopback_port, prev_loopback)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:casein, key)
  defp restore_env(key, val), do: Application.put_env(:casein, key, val)

  test "open/1 persists workspace string ids and http preview URLs" do
    assert {:ok, %Preview{} = preview} =
             Previews.open(@workspace, %{url: "http://localhost:4000", mode: :iframe})

    assert preview.workspace_id == "ws-1"
    assert preview.mode == :tab
    assert preview.trusted
    assert preview.status == :open
    assert preview.metadata["surface_key"] == "localhost:4000"
  end

  test "find_or_open reuses the same workspace origin across routes" do
    assert {:ok, first} =
             Previews.find_or_open(@workspace, %{url: "http://localhost:5173/"})

    assert {:ok, second} =
             Previews.find_or_open(@workspace, %{url: "http://127.0.0.1:5173/settings"})

    assert second.id == first.id
    assert [preview] = Previews.list_for_workspace("ws-1")
    assert preview.id == first.id
  end

  test "trusted_url?/1 accepts allowed localhost URLs and rejects others" do
    assert Previews.trusted_url?("http://0.0.0.0:3000")
    assert Previews.trusted_url?("http://127.0.0.1:5173")
    refute Previews.trusted_url?("http://evil.example:4000")
    refute Previews.trusted_url?("file:///etc/passwd")
  end

  test "close/1 marks preview closed and drops it from open list" do
    {:ok, preview} = Previews.open(@workspace, %{url: "http://localhost:5173"})

    assert {:ok, %Preview{status: :closed}} = Previews.close(preview)
    assert Previews.list_for_workspace("ws-1") == []
  end

  test "close_all_open/1 bulk-closes every open preview for the workspace" do
    {:ok, _} = Previews.open(@workspace, %{url: "http://localhost:4000"})
    {:ok, _} = Previews.open(@workspace, %{url: "http://localhost:5173"})
    {:ok, _} = Previews.open(%{id: "ws-2"}, %{url: "http://localhost:8080"})

    assert 2 = Previews.close_all_open("ws-1")
    assert Previews.list_for_workspace("ws-1") == []
    assert [%Preview{status: :open}] = Previews.list_for_workspace("ws-2")
  end

  test "get_for_workspace/2 scopes by workspace id" do
    {:ok, preview} = Previews.open(@workspace, %{url: "http://localhost:8080"})
    assert %Preview{} = Previews.get_for_workspace(preview.id, "ws-1")
    assert Previews.get_for_workspace(preview.id, "ws-2") == nil
  end

  test "rejects external preview URLs outside the workspace allowlist" do
    assert {:error, %Ecto.Changeset{}} =
             Previews.open(@workspace, %{url: "http://evil.example:4000"})
  end

  test "rejects non-http preview URLs" do
    assert {:error, %Ecto.Changeset{}} =
             Previews.open(@workspace, %{url: "file:///etc/passwd"})
  end

  test "opens trusted v3 workspace surfaces from metadata" do
    ws = %{
      id: "ws-v3",
      metadata: %{
        type: :v3,
        domain_base: "alice.devbox.example.com",
        ports: %{"app" => 10_100, "tidewave" => 11_003}
      }
    }

    assert {:ok, preview} = Previews.open_surface(ws, "app", mode: :iframe)
    assert preview.trusted
    assert preview.mode == :tab
    assert preview.url == "https://alice.devbox.example.com"
    assert preview.metadata["surface"] == "app"
    assert preview.metadata["surface_key"] == "app"
    assert is_list(preview.metadata["allowed_origins"])
  end

  test "open_surface reuses an already-open named surface" do
    ws = %{
      id: "ws-v3-reuse",
      metadata: %{
        type: :v3,
        domain_base: "alice.devbox.example.com",
        ports: %{"app" => 10_100}
      }
    }

    assert {:ok, first} = Previews.open_surface(ws, "app")
    assert {:ok, second} = Previews.open_surface(ws, "app")

    assert second.id == first.id
    assert [_] = Previews.list_for_workspace("ws-v3-reuse")
  end

  test "update_url self-includes only control and app origins, not every navigated target" do
    Application.put_env(:casein, :preview_app_url, "https://devide.example.com")
    Application.put_env(:casein, :preview_loopback_port, 4100)

    workspace = %{id: "ws-1", metadata: %{detected_ports: [5999]}}
    {:ok, preview} = Previews.open(workspace, %{url: "http://localhost:4000"})
    origins_before = preview.metadata["allowed_origins"]

    assert {:ok, %Preview{} = updated} =
             Previews.update_url(preview.id, "ws-1", "http://localhost:5999/dash")

    origins = updated.metadata["allowed_origins"]
    new_origins = origins -- origins_before
    assert Enum.count_until(new_origins, 3) == length(new_origins)
    assert "http://127.0.0.1:4100" in origins
    assert "https://devide.example.com:443" in origins
  end

  test "repeated update_url calls do not grow allowed_origins unboundedly" do
    Application.put_env(:casein, :preview_app_url, "https://devide.example.com")

    {:ok, preview} = Previews.open(@workspace, %{url: "http://localhost:4000"})
    initial_origins = preview.metadata["allowed_origins"]

    preview =
      Enum.reduce(1..50, preview, fn offset, acc ->
        assert {:ok, next} =
                 Previews.update_url(
                   acc.id,
                   "ws-1",
                   "/preview-proxy/ws-1/#{6000 + offset}/page"
                 )

        next
      end)

    origins = preview.metadata["allowed_origins"]
    assert Enum.count_until(origins, 65) == length(origins)

    new_origins = origins -- initial_origins
    assert Enum.count_until(new_origins, 3) == length(new_origins)
  end

  test "discover_surfaces returns manager surfaces for v3 workspaces" do
    ws = %{
      id: "ws-v3",
      metadata: %{
        type: :v3,
        domain_base: "alice.devbox.example.com",
        ports: %{"app" => 10_100}
      }
    }

    surfaces = Previews.discover_surfaces(ws)
    assert Enum.any?(surfaces, &(&1.name == "app" and &1.source == :manager))
  end
end
