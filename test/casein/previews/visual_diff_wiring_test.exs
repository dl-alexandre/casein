defmodule Casein.Previews.VisualDiffWiringTest do
  use Casein.DataCase, async: false

  alias Casein.PreviewControl.Registry
  alias Casein.Previews.Control, as: PreviewControl

  @workspace %{
    id: "ws-visual-diff",
    metadata: %{
      type: :v3,
      domain_base: "alice.devbox.example.com",
      ports: %{"app" => 10_100}
    }
  }

  setup do
    root =
      Path.join(System.tmp_dir!(), "preview-diff-wiring-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    previous = Application.get_env(:casein, :preview_artifacts_root)
    Application.put_env(:casein, :preview_artifacts_root, root)

    _ = Registry.clear()

    on_exit(fn ->
      File.rm_rf(root)

      if previous,
        do: Application.put_env(:casein, :preview_artifacts_root, previous),
        else: Application.delete_env(:casein, :preview_artifacts_root)
    end)

    :ok
  end

  describe "Control → Session → memory adapter" do
    test "click persists diff PNG and strips diff_png_base64" do
      {:ok, session} = PreviewControl.open_session(@workspace, "app")

      assert {:ok, observation} =
               PreviewControl.click(session.id, %{selector: "button[type=submit]"})

      assert observation.diff.diff_pct == 1.5
      assert observation.diff.diff_image_url =~ "/preview-artifacts/ws-visual-diff/"
      assert observation.diff.diff_image_url =~ "-diff.png"
      refute Map.has_key?(observation.diff, :diff_png_base64)
    end

    test "click with diff:false omits diff entirely" do
      {:ok, session} = PreviewControl.open_session(@workspace, "app")

      assert {:ok, observation} =
               PreviewControl.click(session.id, %{
                 selector: "button[type=submit]",
                 diff: false
               })

      refute Map.has_key?(observation, :diff)
    end

    test "type carries diff through last_observation and persists artifact" do
      {:ok, session} = PreviewControl.open_session(@workspace, "app")

      assert {:ok, observation} =
               PreviewControl.type(session.id, "#app", "hello")

      assert observation.diff.diff_image_url =~ "-diff.png"
      refute Map.has_key?(observation.diff, :diff_png_base64)
    end

    test "type with diff:false omits diff" do
      {:ok, session} = PreviewControl.open_session(@workspace, "app")

      assert {:ok, observation} =
               PreviewControl.type(session.id, "#app", "hello", %{diff: false})

      refute Map.has_key?(observation, :diff)
    end

    test "press carries diff through last_observation" do
      {:ok, session} = PreviewControl.open_session(@workspace, "app")

      assert {:ok, observation} = PreviewControl.press(session.id, "Enter")

      assert observation.diff.diff_image_url =~ "-diff.png"
    end

    test "press with diff:false omits diff" do
      {:ok, session} = PreviewControl.open_session(@workspace, "app")

      assert {:ok, observation} =
               PreviewControl.press(session.id, "Enter", %{diff: false})

      refute Map.has_key?(observation, :diff)
    end
  end
end
