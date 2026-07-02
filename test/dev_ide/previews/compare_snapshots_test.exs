defmodule DevIDE.Previews.CompareSnapshotsTest do
  # async: false — mutates :dev_ide app env (differ + artifacts root).
  use ExUnit.Case, async: false

  alias DevIDE.Previews.{Artifacts, Control}

  # A 1x1 PNG so persist_compare_diff has valid base64 to decode + store.
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

  defmodule FakeDiffer do
    @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

    def compare_images(_before_b64, _after_b64, _opts) do
      {:ok,
       %{
         "diff_pct" => 1.5,
         "changed_pixels" => 42,
         "dimensions" => %{"width" => 100, "height" => 50},
         "changed_regions" => [%{"x" => 0, "y" => 0, "width" => 10, "height" => 10}],
         "noise_filtered" => false,
         "diff_png_base64" => "data:image/png;base64," <> @png
       }}
    end
  end

  setup do
    prev_differ = Application.get_env(:dev_ide, :preview_differ)
    prev_root = Application.get_env(:dev_ide, :preview_artifacts_root)
    root = Path.join(System.tmp_dir!(), "cmp-artifacts-#{System.unique_integer([:positive])}")

    Application.put_env(:dev_ide, :preview_differ, FakeDiffer)
    Application.put_env(:dev_ide, :preview_artifacts_root, root)

    on_exit(fn ->
      restore(:preview_differ, prev_differ)
      restore(:preview_artifacts_root, prev_root)
      File.rm_rf(root)
    end)

    ws = "cmp-ws"
    png = Base.decode64!(@png_b64)
    a = Artifacts.store_named_png!(ws, "snap-a", png)
    b = Artifacts.store_named_png!(ws, "snap-b", png)

    %{ws: ws, a: a, b: b}
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)

  test "diffs two persisted artifacts and returns stats + a persisted overlay", %{
    ws: ws,
    a: a,
    b: b
  } do
    assert {:ok, diff} = Control.compare_snapshots(%{id: ws}, a, b)

    assert diff.diff_pct == 1.5
    assert diff.changed_pixels == 42
    assert diff.dimensions == %{"width" => 100, "height" => 50}
    assert diff.changed_regions == [%{"x" => 0, "y" => 0, "width" => 10, "height" => 10}]
    assert diff.noise_filtered == false

    # Overlay persisted + base64 stripped from the response.
    assert String.starts_with?(diff.diff_image_url, "/preview-artifacts/#{ws}/")
    assert String.ends_with?(diff.diff_image_url, "-diff.png")
    refute Map.has_key?(diff, :diff_png_base64)

    # No DOM context for static snapshots.
    refute Map.has_key?(diff, :affected_element_ids)
  end

  test "rejects an artifact path scoped to a different workspace", %{ws: ws, a: a} do
    assert {:error, :workspace_scope_mismatch} =
             Control.compare_snapshots(%{id: ws}, "/preview-artifacts/other-ws/x.png", a)
  end

  test "rejects a non-artifact path (traversal guard)", %{ws: ws, a: a} do
    assert {:error, :invalid_artifact_path} =
             Control.compare_snapshots(%{id: ws}, "/etc/passwd", a)
  end

  test "reports a missing artifact", %{ws: ws} do
    assert {:error, :artifact_not_found} =
             Control.compare_snapshots(
               %{id: ws},
               "/preview-artifacts/#{ws}/nope.png",
               "/preview-artifacts/#{ws}/nope2.png"
             )
  end

  test "accepts a full artifact URL, using only its path", %{ws: ws, a: a, b: b} do
    assert {:ok, diff} =
             Control.compare_snapshots(%{id: ws}, "https://devide.example.com" <> a, b)

    assert diff.diff_pct == 1.5
    assert String.starts_with?(diff.diff_image_url, "/preview-artifacts/#{ws}/")
  end
end
