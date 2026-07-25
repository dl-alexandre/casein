defmodule Casein.Mobile.EvidenceTest do
  use ExUnit.Case, async: false

  alias Casein.Mobile.Card
  alias Casein.Mobile.Evidence
  alias Casein.Previews.Storage.LocalDisk

  @viewer %{id: "mobile-user", email: "mobile-user@example.test"}
  @now ~U[2026-07-24 12:00:00Z]

  setup do
    root = Path.join(System.tmp_dir!(), "casein-mobile-evidence-#{System.unique_integer()}")
    artifacts = Path.join(root, "artifacts")
    workspace_id = "workspace-evidence"
    workspace = Path.join(root, workspace_id)

    previous_root = Application.get_env(:casein, :workspaces_root)
    previous_source = Application.get_env(:casein, :workspace_source)
    previous_artifacts = Application.get_env(:casein, :preview_artifacts_root)

    File.mkdir_p!(workspace)
    Application.put_env(:casein, :workspaces_root, root)
    Application.put_env(:casein, :workspace_source, Casein.WorkspaceSource.Local)
    Application.put_env(:casein, :preview_artifacts_root, artifacts)

    on_exit(fn ->
      File.rm_rf(root)
      restore_env(:workspaces_root, previous_root)
      restore_env(:workspace_source, previous_source)
      restore_env(:preview_artifacts_root, previous_artifacts)
    end)

    {:ok, root: root, workspace: workspace, workspace_id: workspace_id}
  end

  test "projects bounded contained paths, a redacted diff, and exact PWA links", ctx do
    for path <- ["lib/auth.ex", "test/auth_test.exs"] do
      absolute = Path.join(ctx.workspace, path)
      File.mkdir_p!(Path.dirname(absolute))
      File.write!(absolute, "ok")
    end

    {:ok, artifact_path} =
      LocalDisk.put(ctx.workspace_id, "review-shot", "png", {:bytes, "png"})

    card =
      review_card(ctx.workspace_id, %{
        files_changed: ["lib/auth.ex", "test/auth_test.exs"],
        diff_preview: "- token=secret-value\n+ token=safe-value",
        locator: %{
          session_id: "run-1",
          tmux_session: "workspace-session",
          pane: "%2",
          artifact: artifact_path
        }
      })

    evidence = Evidence.project(card, @viewer)

    assert evidence.version == 1
    assert evidence.origin.id == Casein.Origin.id()
    assert evidence.freshness == %{kind: "live", observed_at: @now}
    assert evidence.changed_files.files == ["lib/auth.ex", "test/auth_test.exs"]
    assert evidence.changed_files.count == 2
    refute evidence.changed_files.truncated
    assert evidence.diff.excerpt =~ "token=[REDACTED]"
    refute evidence.diff.excerpt =~ "secret-value"
    assert evidence.artifact.filename == "review-shot.png"
    assert evidence.artifact.media_type == "image/png"

    links = Map.new(evidence.links, &{&1.kind, &1.path})
    assert links["diff"] =~ "/workspaces/#{ctx.workspace_id}?"
    assert links["diff"] =~ "tab=diff"
    assert links["diff"] =~ "pane=%252"
    assert links["preview"] =~ artifact_path
    assert links["artifacts"] =~ "tab=artifacts"
    refute Jason.encode!(evidence) =~ "secret-value"
  end

  test "rejects traversal, symlink escape, origin collision, and mismatched artifacts", ctx do
    outside = Path.join(ctx.root, "outside.txt")
    File.write!(outside, "outside")
    File.ln_s!(outside, Path.join(ctx.workspace, "escape.txt"))

    {:ok, other_artifact} =
      LocalDisk.put("other-workspace", "other", "png", {:bytes, "png"})

    card =
      review_card(ctx.workspace_id, %{
        files_changed: [
          "../outside.txt",
          "escape.txt",
          String.duplicate("x", 241),
          ".git/config"
        ],
        diff_preview: "",
        locator: %{
          artifact: other_artifact,
          origin_id: "tampered-origin",
          token: "must-not-render"
        }
      })

    assert Evidence.project(card, @viewer) == nil
    assert Evidence.project(card, %{}) == nil
  end

  test "enforces file, line, and byte bounds with graceful missing evidence fallback", ctx do
    paths =
      for index <- 1..12 do
        path = "lib/file_#{index}.ex"
        absolute = Path.join(ctx.workspace, path)
        File.mkdir_p!(Path.dirname(absolute))
        File.write!(absolute, "ok")
        path
      end

    diff =
      1..40
      |> Enum.map_join("\n", fn index -> "+ #{index} " <> String.duplicate("é", 400) end)

    evidence =
      ctx.workspace_id
      |> review_card(%{files_changed: paths, diff_preview: diff})
      |> Evidence.project(@viewer)

    assert evidence.changed_files.count == 8
    assert evidence.changed_files.truncated
    assert length(String.split(evidence.diff.excerpt, "\n")) <= 24
    assert byte_size(evidence.diff.excerpt) <= 4_096
    assert evidence.diff.truncated

    assert ctx.workspace_id
           |> review_card(%{files_changed: [], diff_preview: nil})
           |> Evidence.project(@viewer) == nil
  end

  defp review_card(workspace_id, evidence) do
    Card.needs_review(
      %{
        user_id: @viewer.id,
        workspace_id: workspace_id,
        workspace_name: workspace_id,
        session_id: "run-1",
        review_count: 1,
        files_changed: evidence[:files_changed],
        diff_preview: evidence[:diff_preview],
        locator: evidence[:locator] || %{}
      },
      @now
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:casein, key)
  defp restore_env(key, value), do: Application.put_env(:casein, key, value)
end
