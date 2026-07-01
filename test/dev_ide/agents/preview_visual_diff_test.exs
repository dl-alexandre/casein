defmodule DevIDE.Agents.PreviewVisualDiffTest do
  use ExUnit.Case, async: true

  alias DevIDE.Agents.PreviewTools
  alias DevIDE.Previews.Artifacts

  describe "compute_affected_element_ids/2" do
    test "maps changed regions to overlapping element ids" do
      observation = %{
        dom_summary: %{
          elements: [
            %{
              selector: "#folder_path",
              role: "textbox",
              name: "folder_path",
              bounds: %{x: 40, y: 130, width: 200, height: 36}
            },
            %{
              selector: "#submit",
              role: "button",
              name: "Save",
              bounds: %{x: 400, y: 500, width: 80, height: 32}
            }
          ]
        }
      }

      regions = [%{"x" => 40, "y" => 130, "width" => 1200, "height" => 36}]

      assert [%{element_id: "el_1", name: "folder_path", role: "textbox"}] =
               PreviewTools.compute_affected_element_ids(observation, regions)
    end

    test "returns empty list when no regions overlap bounds" do
      observation = %{
        dom_summary: %{
          elements: [
            %{
              selector: "#other",
              role: "button",
              name: "Other",
              bounds: %{x: 0, y: 0, width: 10, height: 10}
            }
          ]
        }
      }

      regions = [%{"x" => 200, "y" => 200, "width" => 50, "height" => 50}]

      assert PreviewTools.compute_affected_element_ids(observation, regions) == []
    end

    test "detects partial overlap" do
      observation = %{
        dom_summary: %{
          elements: [
            %{
              selector: "#field",
              role: "textbox",
              name: "field",
              bounds: %{x: 90, y: 90, width: 40, height: 40}
            }
          ]
        }
      }

      regions = [%{"x" => 100, "y" => 100, "width" => 20, "height" => 20}]

      assert [%{element_id: "el_1"}] =
               PreviewTools.compute_affected_element_ids(observation, regions)
    end

    test "skips elements without bounds" do
      observation = %{
        dom_summary: %{
          selectors: ["#ghost"],
          elements: [
            %{
              selector: "#real",
              role: "button",
              name: "Real",
              bounds: %{x: 0, y: 0, width: 100, height: 40}
            }
          ]
        }
      }

      regions = [%{"x" => 0, "y" => 0, "width" => 100, "height" => 40}]

      assert [%{element_id: "el_1", name: "Real"}] =
               PreviewTools.compute_affected_element_ids(observation, regions)
    end
  end

  describe "preview_diff_opts/1" do
    test "passes diff:false through to the Playwright params" do
      assert %{diff: false} = PreviewTools.preview_diff_opts_for_test(%{diff: false})
      assert %{diff: false} = PreviewTools.preview_diff_opts_for_test(%{"diff" => "false"})
      # JSON callers send a boolean under a string key — the value `false` must be
      # distinguished from a missing key (regression: `Map.get || Map.get` swallowed it).
      assert %{diff: false} = PreviewTools.preview_diff_opts_for_test(%{"diff" => false})
    end

    test "defaults to empty opts when diff is not disabled" do
      assert %{} = PreviewTools.preview_diff_opts_for_test(%{})
      assert %{} = PreviewTools.preview_diff_opts_for_test(%{diff: true})
    end
  end

  describe "enrich_observation_diff/1" do
    test "sets elements_truncated when dom_summary hit the 40-element cap" do
      elements =
        Enum.map(1..40, fn index ->
          %{
            selector: "#e#{index}",
            role: "button",
            name: "btn-#{index}",
            bounds: %{x: 0, y: index, width: 10, height: 10}
          }
        end)

      observation = %{
        dom_summary: %{elements: elements, elements_truncated: true},
        diff: %{
          changed_regions: [%{"x" => 0, "y" => 1, "width" => 10, "height" => 1}],
          changed_pixels: 100
        }
      }

      enriched = PreviewTools.enrich_observation_diff_for_test(observation)

      assert enriched.diff.elements_truncated == true
      assert enriched.diff.elements_considered == 40

      assert [%{element_id: "el_1", name: "btn-1", role: "button"}] =
               enriched.diff.affected_element_ids
    end

    test "sets elements_truncated false when dom_summary is under the cap" do
      observation = %{
        dom_summary: %{
          elements: [
            %{
              selector: "#only",
              role: "button",
              name: "only",
              bounds: %{x: 0, y: 0, width: 20, height: 20}
            }
          ],
          elements_truncated: false
        },
        diff: %{
          changed_regions: [%{"x" => 0, "y" => 0, "width" => 20, "height" => 20}],
          changed_pixels: 400
        }
      }

      enriched = PreviewTools.enrich_observation_diff_for_test(observation)

      assert enriched.diff.elements_truncated == false
      assert enriched.diff.elements_considered == 1
    end

    test "leaves observation unchanged when diff is absent" do
      observation = %{dom_summary: %{elements: []}, url: "http://example.test/"}

      assert PreviewTools.enrich_observation_diff_for_test(observation) == observation
    end
  end

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
