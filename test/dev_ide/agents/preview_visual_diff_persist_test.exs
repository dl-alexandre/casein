defmodule DevIDE.Agents.PreviewVisualDiffPersistTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Previews.Artifacts

  describe "persist_diff_artifact wiring" do
    setup do
      root =
        Path.join(
          System.tmp_dir!(),
          "preview-diff-artifacts-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      previous = Application.get_env(:dev_ide, :preview_artifacts_root)
      Application.put_env(:dev_ide, :preview_artifacts_root, root)

      on_exit(fn ->
        File.rm_rf(root)

        if previous,
          do: Application.put_env(:dev_ide, :preview_artifacts_root, previous),
          else: Application.delete_env(:dev_ide, :preview_artifacts_root)
      end)

      :ok
    end

    test "stores diff PNG and returns a servable diff_image_url" do
      png =
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )

      url =
        Artifacts.store_named_png!(
          "ws-diff-test",
          "#{System.unique_integer([:positive])}-diff",
          png
        )

      assert url =~ "/preview-artifacts/ws-diff-test/"
      assert url =~ "-diff.png"
      assert File.exists?(Artifacts.safe_path!("ws-diff-test", Path.basename(url)))
    end
  end
end
