defmodule Casein.Previews.PaneTest do
  use Casein.DataCase, async: false

  alias Casein.Previews.Pane, as: PreviewPane
  alias Casein.PreviewPanes
  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  setup do
    prev_tmux = Application.get_env(:casein, :tmux_adapter)
    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_persistence = Application.get_env(:casein, :preview_pane_persistence_enabled)

    Application.put_env(:casein, :tmux_adapter, FakeAdapter)
    Application.put_env(:casein, :preview_pane_persistence_enabled, true)
    PreviewPanes.clear()
    FakeState.delete(:fake_tmux_windows)
    FakeState.delete(:fake_tmux_panes)

    on_exit(fn ->
      PreviewPanes.clear()
      FakeState.delete(:fake_tmux_windows)
      FakeState.delete(:fake_tmux_panes)
      restore(:tmux_adapter, prev_tmux)
      restore(:workspaces_root, prev_root)
      restore(:preview_pane_persistence_enabled, prev_persistence)
    end)

    {:ok, workspace: seed_workspace!(), session: "preview-pane-test", pane_id: "%42"}
  end

  describe "attach/2" do
    test "registers a preview pane from node command payload", ctx do
      seed_session!(ctx.session, ctx.pane_id)

      node = %{command: "http://localhost:3000", viewport: %{width: 1280, height: 720}}
      pane_ctx = %{pane_id: ctx.pane_id, workspace_id: "ws-1", tmux_session: ctx.session}

      assert {:ok, returned_id} = PreviewPane.attach(node, pane_ctx)
      assert returned_id == ctx.pane_id
      assert %{url: "http://localhost:3000"} = PreviewPanes.get_by_pane(ctx.pane_id)
    end

    test "is idempotent when the same pane already shows the same URL", ctx do
      seed_session!(ctx.session, ctx.pane_id)
      node = %{command: "http://localhost:3000"}
      pane_ctx = %{pane_id: ctx.pane_id, workspace_id: "ws-1", tmux_session: ctx.session}

      assert {:ok, _} = PreviewPane.attach(node, pane_ctx)
      assert {:ok, returned_id} = PreviewPane.attach(node, pane_ctx)
      assert returned_id == ctx.pane_id
    end

    test "returns error when pane_id is missing from context" do
      assert {:error, {:missing, :pane_id}} =
               PreviewPane.attach(%{command: "http://localhost:3000"}, %{})
    end

    test "returns error when preview URL is missing from node" do
      assert {:error, :missing_preview_url} =
               PreviewPane.attach(%{}, %{pane_id: "%1"})
    end
  end

  describe "serialize/1" do
    test "returns bare preview type when pane is not registered" do
      assert %{"type" => "preview"} = PreviewPane.serialize("%missing")
      refute Map.has_key?(PreviewPane.serialize("%missing"), "url")
    end

    test "includes url when pane is registered", ctx do
      seed_session!(ctx.session, ctx.pane_id)

      {:ok, _} =
        PreviewPanes.register(%{
          "pane_id" => ctx.pane_id,
          "url" => "http://localhost:4000/app",
          "cwd" => ctx.workspace,
          "tmux_session" => ctx.session
        })

      assert %{
               "type" => "preview",
               "command" => "http://localhost:4000/app",
               "url" => "http://localhost:4000/app"
             } = PreviewPane.serialize(ctx.pane_id)
    end
  end

  describe "terminate/1" do
    test "deregisters the preview pane", ctx do
      seed_session!(ctx.session, ctx.pane_id)

      {:ok, _} =
        PreviewPanes.register(%{
          "pane_id" => ctx.pane_id,
          "url" => "http://localhost:5173",
          "cwd" => ctx.workspace,
          "tmux_session" => ctx.session
        })

      assert :ok = PreviewPane.terminate(ctx.pane_id)
      assert PreviewPanes.get_by_pane(ctx.pane_id) == nil
    end
  end

  describe "render_payload/1" do
    test "returns empty map when pane is not registered" do
      assert %{} = PreviewPane.render_payload("%ghost")
    end

    test "returns preview metadata for a registered pane", ctx do
      seed_session!(ctx.session, ctx.pane_id)

      {:ok, reg} =
        PreviewPanes.register(%{
          "pane_id" => ctx.pane_id,
          "url" => "http://localhost:5173",
          "cwd" => ctx.workspace,
          "tmux_session" => ctx.session
        })

      payload = PreviewPane.render_payload(ctx.pane_id)

      assert payload.url == reg.url
      assert payload.display_url == reg.display_url
      assert payload.viewport == reg.viewport
      assert payload.mode == "iframe"
    end
  end

  describe "handle_input/2" do
    test "returns unsupported for unknown input types" do
      assert {:error, :unsupported_preview_input} =
               PreviewPane.handle_input("%1", %{"type" => "zoom"})
    end

    test "returns not_found when pane is missing" do
      assert {:error, :not_found} = PreviewPane.handle_input("%missing", %{"type" => "reload"})
    end
  end

  describe "set_active/2" do
    test "is a no-op for preview panes" do
      assert :ok = PreviewPane.set_active("%1", true)
      assert :ok = PreviewPane.set_active("%1", false)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)

  defp seed_workspace! do
    root = Path.join(System.tmp_dir!(), "preview-pane-#{System.unique_integer([:positive])}")
    path = Path.join(root, "ws")
    File.mkdir_p!(path)
    Application.put_env(:casein, :workspaces_root, root)
    path
  end

  defp seed_session!(session, pane_id) do
    FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "bash", active: true, panes: 1, activity: 0}]
    })

    FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: pane_id,
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "devide-preview",
          current_path: "/tmp"
        }
      ]
    })
  end
end
