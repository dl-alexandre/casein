defmodule DevIdeWeb.WorkspaceLive.Show.SidePanelsTest do
  use DevIDE.TestCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias DevIdeWeb.WorkspaceLive.Show.RunPanel
  alias DevIdeWeb.WorkspaceLive.Show.SidePanels

  # ----- Shared fixtures -------------------------------------------------

  defp file_entry(name, rel_path, kind) do
    %DevIDE.Files.Entry{
      name: name,
      rel_path: rel_path,
      kind: kind,
      size: 42,
      mtime: nil
    }
  end

  defp base_files_assigns(overrides) do
    %{
      host_loc: {:ok, "/work"},
      selected_dir: "",
      new_input: nil,
      tree_error: nil,
      tree: %{},
      open_file: nil,
      file_render_mode: nil,
      rename_input: nil,
      delete_confirm: nil,
      node_rename: nil,
      node_delete: nil,
      save_error: nil,
      file_error: nil,
      project_meta: nil,
      tooling: nil
    }
    |> Map.merge(Map.new(overrides))
  end

  # ----- files_panel/1 --------------------------------------------------

  describe "files_panel/1" do
    test "renders error when host_loc is not ok" do
      assigns = base_files_assigns(host_loc: {:error, :nope})

      html = rendered_to_string(~H"<SidePanels.files_panel {assigns} />")

      assert html =~ "No host path; cannot list files."
      refute html =~ "+File"
    end

    test "renders toolbar with root selected_dir and empty tree (loading state)" do
      assigns = base_files_assigns([])

      html = rendered_to_string(~H"<SidePanels.files_panel {assigns} />")

      assert html =~ "+File"
      assert html =~ "+Dir"
      # selected_dir == "" renders "/"
      assert html =~ "/"
      # empty tree -> render_tree_node hits the loading branch (collapsed default)
      assert html =~ "(loading…)"
      # no open_file -> select-a-file hint
      assert html =~ "Select a file to view."
    end

    test "shows the non-root selected_dir verbatim" do
      assigns = base_files_assigns(selected_dir: "lib/sub")

      html = rendered_to_string(~H"<SidePanels.files_panel {assigns} />")

      assert html =~ "lib/sub"
    end

    test "renders the new-file input form when new_input is a file tuple" do
      assigns = base_files_assigns(new_input: {:file, ""})

      html = rendered_to_string(~H"<SidePanels.files_panel {assigns} />")

      assert html =~ "tree-new-name-input"
      assert html =~ ~s(placeholder="filename")
      assert html =~ "tree:create"
    end

    test "renders the new-dir input form when new_input is a dir tuple" do
      assigns = base_files_assigns(new_input: {:dir, ""})

      html = rendered_to_string(~H"<SidePanels.files_panel {assigns} />")

      assert html =~ ~s(placeholder="dir name")
    end

    test "renders the tree error message" do
      assigns = base_files_assigns(tree_error: "boom-tree-error")

      html = rendered_to_string(~H"<SidePanels.files_panel {assigns} />")

      assert html =~ "boom-tree-error"
    end

    test "renders an expanded tree with a file and a directory entry" do
      tree = %{
        "" =>
          {:expanded,
           [
             file_entry("README.md", "README.md", :file),
             file_entry("lib", "lib", :dir)
           ]}
      }

      assigns = base_files_assigns(tree: tree, selected_dir: "lib")

      html = rendered_to_string(~H"<SidePanels.files_panel {assigns} />")

      # file branch
      assert html =~ "README.md"
      assert html =~ "tree:open"
      # dir branch
      assert html =~ "lib/"
      assert html =~ "tree:toggle"
      assert html =~ "tree:select_dir"
      # selected_dir == e.rel_path highlights the dir's sel button
      assert html =~ "text-blue-700"
    end

    test "recurses into an expanded child directory" do
      tree = %{
        "" => {:expanded, [file_entry("lib", "lib", :dir)]},
        "lib" => {:expanded, [file_entry("app.ex", "lib/app.ex", :file)]}
      }

      assigns = base_files_assigns(tree: tree)

      html = rendered_to_string(~H"<SidePanels.files_panel {assigns} />")

      assert html =~ "lib/"
      # nested file rendered via recursion
      assert html =~ "app.ex"
    end

    test "renders open_file header, size, and symbols panel" do
      open_file = %{
        path: "lib/foo.ex",
        size: 128,
        content: "defmodule Foo do\n  def bar, do: 1\nend\n"
      }

      assigns = base_files_assigns(open_file: open_file)

      html = rendered_to_string(~H"<SidePanels.files_panel {assigns} />")

      assert html =~ "lib/foo.ex"
      assert html =~ "128b"
      assert html =~ "Save"
      assert html =~ "Rename"
      assert html =~ "Delete"
      # symbols panel (module Foo + function bar)
      assert html =~ "Symbols"
      assert html =~ "Foo"
      assert html =~ "bar"
    end

    test "renders source and rendered mode buttons for markdown files" do
      open_file = %{path: "README.md", size: 18, content: "# Title\n"}
      assigns = base_files_assigns(open_file: open_file, file_render_mode: "rendered")

      html = rendered_to_string(~H"<SidePanels.files_panel {assigns} />")

      assert html =~ "Source"
      assert html =~ "Rendered"
      assert html =~ "devide:file-mode"
    end

    test "does not render markdown mode buttons for non-markdown files" do
      open_file = %{path: "lib/foo.ex", size: 1, content: ""}
      assigns = base_files_assigns(open_file: open_file)

      html = rendered_to_string(~H"<SidePanels.files_panel {assigns} />")

      refute html =~ "Rendered"
      refute html =~ "devide:file-mode"
    end

    test "renders rename input form when rename_input present" do
      open_file = %{path: "lib/foo.ex", size: 1, content: ""}
      assigns = base_files_assigns(open_file: open_file, rename_input: "lib/renamed.ex")

      html = rendered_to_string(~H"<SidePanels.files_panel {assigns} />")

      assert html =~ "file:rename_submit"
      assert html =~ "lib/renamed.ex"
    end

    test "renders the delete confirmation bar" do
      open_file = %{path: "lib/foo.ex", size: 1, content: ""}
      assigns = base_files_assigns(open_file: open_file, delete_confirm: "lib/foo.ex")

      html = rendered_to_string(~H"<SidePanels.files_panel {assigns} />")

      assert html =~ "file:delete_confirm"
      assert html =~ "confirm"
      assert html =~ "cancel"
    end

    test "renders the save error banner" do
      open_file = %{path: "lib/foo.ex", size: 1, content: ""}
      assigns = base_files_assigns(open_file: open_file, save_error: "write failed xyz")

      html = rendered_to_string(~H"<SidePanels.files_panel {assigns} />")

      assert html =~ "write failed xyz"
    end

    test "renders the file_error when no file open" do
      assigns = base_files_assigns(file_error: "could not read file")

      html = rendered_to_string(~H"<SidePanels.files_panel {assigns} />")

      assert html =~ "could not read file"
    end

    test "renders project card with mix/phoenix flags and no tooling" do
      project_meta = %{
        mix?: true,
        umbrella?: false,
        phoenix?: true,
        live_view?: false,
        ecto?: true,
        formatter?: false
      }

      assigns = base_files_assigns(project_meta: project_meta, tooling: nil)

      html = rendered_to_string(~H"<SidePanels.files_panel {assigns} />")

      assert html =~ "Project"
      assert html =~ "Mix:"
      assert html =~ "yes"
      assert html =~ "no"
      # tooling nil -> no Lexical/ElixirLS rows
      refute html =~ "Lexical:"
    end

    test "renders tooling rows (detected/missing) inside project card" do
      project_meta = %{
        mix?: true,
        umbrella?: true,
        phoenix?: true,
        live_view?: true,
        ecto?: true,
        formatter?: true
      }

      tooling = %{
        lexical?: true,
        mix_lock_lexical?: false,
        elixir_ls?: false,
        mix_lock_elixir_ls?: false
      }

      assigns = base_files_assigns(project_meta: project_meta, tooling: tooling)

      html = rendered_to_string(~H"<SidePanels.files_panel {assigns} />")

      assert html =~ "Lexical:"
      assert html =~ "ElixirLS:"
      assert html =~ "detected"
      assert html =~ "missing"
    end

    test "symbols panel shows 'No symbols' for content with no symbols" do
      open_file = %{path: "lib/empty.ex", size: 0, content: "# just a comment\n"}
      assigns = base_files_assigns(open_file: open_file)

      html = rendered_to_string(~H"<SidePanels.files_panel {assigns} />")

      assert html =~ "Symbols"
      assert html =~ "No symbols."
    end

    test "symbols panel shows the HEEx-unsupported message for .heex files" do
      open_file = %{path: "lib/page.heex", size: 5, content: "<div>hi</div>"}
      assigns = base_files_assigns(open_file: open_file)

      html = rendered_to_string(~H"<SidePanels.files_panel {assigns} />")

      assert html =~ "HEEx symbols not supported yet."
    end
  end

  # ----- search_panel/1 -------------------------------------------------

  defp base_search_assigns(overrides) do
    %{
      search_results: [],
      search_query: "",
      search_state: :idle
    }
    |> Map.merge(Map.new(overrides))
  end

  defp search_result(path, line, column, preview) do
    %DevIDE.Search.Result{path: path, line: line, column: column, preview: preview}
  end

  describe "search_panel/1" do
    test "renders the idle hint state" do
      assigns = base_search_assigns(search_state: :idle)

      html = rendered_to_string(~H"<SidePanels.search_panel {assigns} />")

      assert html =~ "search:run"
      assert html =~ "press Enter"
      # rg availability line is always present
      assert html =~ "rg:"
    end

    test "renders the empty / no-matches state" do
      assigns = base_search_assigns(search_state: :empty)

      html = rendered_to_string(~H"<SidePanels.search_panel {assigns} />")

      assert html =~ "No matches."
    end

    test "echoes the current search query into the input" do
      assigns = base_search_assigns(search_query: "needle123", search_state: :idle)

      html = rendered_to_string(~H"<SidePanels.search_panel {assigns} />")

      assert html =~ "needle123"
    end

    test "renders grouped results with line, column, and preview" do
      results = [
        search_result("lib/a.ex", 10, 4, "alpha match"),
        search_result("lib/a.ex", 22, nil, "beta match"),
        search_result("lib/b.ex", 3, 1, "gamma match")
      ]

      assigns = base_search_assigns(search_results: results, search_state: :ok)

      html = rendered_to_string(~H"<SidePanels.search_panel {assigns} />")

      # summary counts: 3 matches in 2 files
      assert html =~ "3 match(es)"
      assert html =~ "2 file(s)"
      # grouped file headers
      assert html =~ "lib/a.ex"
      assert html =~ "lib/b.ex"
      # line + column rendering (column present -> ":4")
      assert html =~ ":10"
      assert html =~ ":4"
      # column nil -> just the line, no extra colon segment for that match
      assert html =~ ":22"
      # previews
      assert html =~ "alpha match"
      assert html =~ "beta match"
      assert html =~ "gamma match"
      assert html =~ "annotation:open"
    end

    test "renders an error state with the rg_missing message" do
      assigns = base_search_assigns(search_state: {:error, :rg_missing})

      html = rendered_to_string(~H"<SidePanels.search_panel {assigns} />")

      assert html =~ "ripgrep (rg) is not installed"
    end

    test "renders an error state with the timeout message" do
      assigns = base_search_assigns(search_state: {:error, :timeout})

      html = rendered_to_string(~H"<SidePanels.search_panel {assigns} />")

      assert html =~ "search timed out"
    end

    test "renders an error state with a generic fallback message" do
      assigns = base_search_assigns(search_state: {:error, :weird_thing})

      html = rendered_to_string(~H"<SidePanels.search_panel {assigns} />")

      assert html =~ "search failed"
      assert html =~ "weird_thing"
    end
  end

  # ----- diff_panel/1 ---------------------------------------------------

  defp base_diff_assigns(overrides) do
    %{
      git_status: [],
      open_file: nil,
      file_diff: nil
    }
    |> Map.merge(Map.new(overrides))
  end

  describe "diff_panel/1" do
    test "renders 'No changes.' and 'Select a file' with empty status and no open file" do
      assigns = base_diff_assigns([])

      html = rendered_to_string(~H"<SidePanels.diff_panel {assigns} />")

      assert html =~ "No changes."
      assert html =~ "Select a file to view its diff."
    end

    test "renders the changes list with status badges for each kind" do
      git_status = [
        %{path: "new.ex", x: "?", y: "?"},
        %{path: "added.ex", x: "A", y: " "},
        %{path: "gone.ex", x: "D", y: " "},
        %{path: "mod.ex", x: " ", y: "M"},
        %{path: "renamed.ex", x: "R", y: " "}
      ]

      assigns = base_diff_assigns(git_status: git_status)

      html = rendered_to_string(~H"<SidePanels.diff_panel {assigns} />")

      # count badge in the header
      assert html =~ "5"
      assert html =~ "new.ex"
      assert html =~ "added.ex"
      assert html =~ "gone.ex"
      assert html =~ "mod.ex"
      assert html =~ "renamed.ex"
      # badge color classes exercised by git_status_badge_class
      assert html =~ "text-violet-700"
      assert html =~ "text-emerald-700"
      assert html =~ "text-rose-700"
      assert html =~ "text-amber-700"
      # R/" " hits the catch-all zinc branch
      assert html =~ "text-zinc-600"
    end

    test "highlights the open file's entry in the changes list" do
      git_status = [%{path: "mod.ex", x: " ", y: "M"}]
      open_file = %{path: "mod.ex", size: 1, content: ""}

      assigns = base_diff_assigns(git_status: git_status, open_file: open_file, file_diff: nil)

      html = rendered_to_string(~H"<SidePanels.diff_panel {assigns} />")

      assert html =~ "border border-zinc-300"
      # open_file set but file_diff nil -> "No diff for ..." branch
      assert html =~ "No diff for"
      assert html =~ "mod.ex"
    end

    test "renders a full diff with added, removed, context, hunk and header lines" do
      diff = """
      diff --git a/foo.ex b/foo.ex
      index 123..456 100644
      --- a/foo.ex
      +++ b/foo.ex
      @@ -1,3 +1,3 @@
       context line
      -removed line
      +added line
      """

      open_file = %{path: "foo.ex", size: 10, content: ""}

      assigns = base_diff_assigns(open_file: open_file, file_diff: diff)

      html = rendered_to_string(~H"<SidePanels.diff_panel {assigns} />")

      # all diff_line_class branches
      assert html =~ "text-zinc-500" || html =~ "text-zinc-400"
      assert html =~ "text-cyan-300"
      assert html =~ "text-emerald-300"
      assert html =~ "text-rose-300"
      assert html =~ "text-zinc-300"
      # content carried through
      assert html =~ "context line"
      assert html =~ "removed line"
      assert html =~ "added line"
      # diff_stat_label: +1 added, -1 removed (excludes +++/---)
      assert html =~ "+1"
      assert html =~ "1"
    end
  end

  # ----- run_panel/1 (via Run tab) ----------------------------------------------------

  defp base_run_assigns(overrides) do
    %{
      host_loc: {:ok, "/work"},
      active_run: nil,
      run_ledger: [],
      selected_run_id: nil,
      selected_run_timeline: [],
      selected_run_summary: nil,
      selected_run_failure_reason: nil,
      selected_run_can_retry: false,
      selected_run_artifacts: []
    }
    |> Map.merge(Map.new(overrides))
  end

  describe "run_panel/1 (via Run tab)" do
    test "renders the run panel error when host_loc is unavailable" do
      assigns = base_run_assigns(host_loc: {:error, :no_path})

      html = rendered_to_string(~H"<RunPanel.run_panel {assigns} />")

      assert html =~ "Cannot run commands: workspace path unavailable."
    end

    test "renders the empty run panel (no active run, empty ledger)" do
      assigns = base_run_assigns([])

      html = rendered_to_string(~H"<RunPanel.run_panel {assigns} />")

      assert html =~ "No runs yet."
      assert html =~ "Run ledger"
      assert html =~ "No runs recorded."
      assert html =~ "Select a run to inspect its canonical events."
    end

    test "renders an active running run with cancel button and buffer" do
      active_run = %{
        status: :running,
        argv: ["mix", "test"],
        exit_code: nil,
        started_at: ~U[2026-06-24 10:00:00Z],
        finished_at: nil,
        buffer: "running output line"
      }

      assigns = base_run_assigns(active_run: active_run)

      html = rendered_to_string(~H"<RunPanel.run_panel {assigns} />")

      assert html =~ "cancel"
      assert html =~ "mix test"
      assert html =~ "running output line"
      assert html =~ "started"
    end

    test "renders a finished active run with exit code and finished timestamp" do
      active_run = %{
        status: :succeeded,
        argv: ["mix", "compile"],
        exit_code: 0,
        started_at: ~U[2026-06-24 10:00:00Z],
        finished_at: ~U[2026-06-24 10:01:00Z],
        buffer: "done"
      }

      assigns = base_run_assigns(active_run: active_run)

      html = rendered_to_string(~H"<RunPanel.run_panel {assigns} />")

      assert html =~ "exit="
      assert html =~ "finished"
      assert html =~ "mix compile"
    end

    test "renders the run ledger with a selected run highlighted" do
      ledger = [
        %{
          id: "run-1",
          command_id: "mix-test",
          status: "succeeded",
          protocol: "ledger",
          assignment_id: "assign-9",
          finished_at: "2026-06-24T10:01:00Z"
        }
      ]

      assigns = base_run_assigns(run_ledger: ledger, selected_run_id: "run-1")

      html = rendered_to_string(~H"<RunPanel.run_panel {assigns} />")

      assert html =~ "run-ledger-run-run-1"
      assert html =~ "mix-test"
      assert html =~ "succeeded"
      assert html =~ "assignment=assign-9"
      assert html =~ "border-zinc-900"
    end

    test "renders a selected-run timeline with summary, failure surface, retry and artifacts" do
      timeline = [
        %{
          id: "evt-1",
          action: "run.command_denied",
          inserted_at: ~U[2026-06-24 10:00:00Z],
          decision: :deny,
          target_ref: "mix-test",
          reason: :not_allowed,
          metadata: %{"noun" => "command"}
        }
      ]

      summary = %{
        status: "denied",
        command_id: "mix-test",
        assignment_id: "assign-9",
        exit_code: nil
      }

      artifacts = [
        %{
          type: "command_output",
          command_id: "mix-test",
          status: "denied",
          exit_code: 1,
          output_truncated: true,
          output: "denied artifact output"
        },
        %{type: "mystery"}
      ]

      assigns =
        base_run_assigns(
          selected_run_id: "run-1",
          selected_run_timeline: timeline,
          selected_run_summary: summary,
          selected_run_failure_reason: "policy denied",
          selected_run_can_retry: true,
          selected_run_artifacts: artifacts
        )

      html = rendered_to_string(~H"<RunPanel.run_panel {assigns} />")

      # summary block
      assert html =~ "run-ledger-summary"
      assert html =~ "denied"
      assert html =~ "assign-9"
      # failure surface (denied is a failed status)
      assert html =~ "run-failure-surface"
      assert html =~ "Failed"
      assert html =~ "policy denied"
      # retry button
      assert html =~ "run-retry-btn"
      # timeline event
      assert html =~ "run.command_denied"
      assert html =~ "command"
      assert html =~ "not_allowed"
      # artifacts: known command_output + unknown fallback
      assert html =~ "denied artifact output"
      assert html =~ "truncated"
      assert html =~ "exit=1"
      assert html =~ "Unknown artifact."
    end

    test "renders a non-failed selected run summary without failure surface" do
      timeline = [
        %{
          id: "evt-2",
          action: "run.succeeded",
          inserted_at: ~U[2026-06-24 10:00:00Z],
          decision: :allow,
          target_ref: "mix-test",
          reason: nil,
          metadata: %{}
        }
      ]

      summary = %{status: "succeeded", command_id: "mix-test", exit_code: 0}

      assigns =
        base_run_assigns(
          selected_run_id: "run-2",
          selected_run_timeline: timeline,
          selected_run_summary: summary,
          selected_run_artifacts: []
        )

      html = rendered_to_string(~H"<RunPanel.run_panel {assigns} />")

      assert html =~ "run-ledger-summary"
      refute html =~ "run-failure-surface"
      # empty artifacts branch
      assert html =~ "No artifacts recorded for this run."
      # allow-decision dot/verb classes
      assert html =~ "bg-green-600"
      assert html =~ "text-green-700"
    end
  end

  # ----- artifact_gallery_panel/1 --------------------------------------

  describe "artifact_gallery_panel/1" do
    test "renders the empty state and refresh control" do
      assigns = %{artifact_projects: [], artifact_projects_error: nil}

      html = rendered_to_string(~H"<SidePanels.artifact_gallery_panel {assigns} />")

      assert html =~ "artifact-gallery-panel"
      assert html =~ "0 artifacts"
      assert html =~ "No artifacts yet."
      assert html =~ "artifact:refresh"
    end

    test "renders artifact project cards with preview actions" do
      assigns = %{
        artifact_projects: [
          %{
            id: "art-demo",
            name: "Demo Artifact",
            kind: "static",
            status: "provisioned",
            branch: "artifact/demo",
            preview_url: "http://localhost:4100",
            worktree_path: "/tmp/artifacts/demo",
            prompt_history: ["first", "polish the dashboard"],
            updated_at: ~U[2026-07-04 02:00:00Z]
          }
        ],
        artifact_projects_error: nil
      }

      html = rendered_to_string(~H"<SidePanels.artifact_gallery_panel {assigns} />")

      assert html =~ "1 artifact"
      assert html =~ "Demo Artifact"
      assert html =~ "provisioned"
      assert html =~ "artifact/demo"
      assert html =~ "http://localhost:4100"
      assert html =~ "/tmp/artifacts/demo"
      assert html =~ "polish the dashboard"
      assert html =~ "artifact:inspect"
      assert html =~ "artifact:serve"
      assert html =~ "artifact:open"
      assert html =~ ~s(phx-value-artifact-id="art-demo")
    end

    test "renders selected artifact detail with same-origin embedded preview" do
      assigns = %{
        artifact_projects: [
          %{
            id: "art-demo",
            name: "Demo Artifact",
            kind: "static",
            status: "live",
            branch: "artifact/demo",
            preview_url: "/preview-proxy/workspace/4100/index.html",
            worktree_path: "/tmp/artifacts/demo",
            prompt_history: ["build the dashboard"],
            updated_at: ~U[2026-07-04 02:00:00Z]
          }
        ],
        artifact_projects_error: nil,
        artifact_selected_id: "art-demo"
      }

      html = rendered_to_string(~H"<SidePanels.artifact_gallery_panel {assigns} />")

      assert html =~ "artifact-detail-art-demo"
      assert html =~ "artifact-embedded-preview"
      assert html =~ ~s(src="/preview-proxy/workspace/4100/index.html")
      assert html =~ "ring-primary/25"
      refute html =~ "artifact-embedded-preview-unavailable"
    end

    test "renders selected artifact detail fallback for off-origin previews" do
      assigns = %{
        artifact_projects: [
          %{
            id: "art-demo",
            name: "Demo Artifact",
            kind: "static",
            status: "live",
            branch: "artifact/demo",
            preview_url: "http://localhost:4100",
            worktree_path: "/tmp/artifacts/demo",
            prompt_history: ["build the dashboard"],
            updated_at: ~U[2026-07-04 02:00:00Z]
          }
        ],
        artifact_projects_error: nil,
        artifact_selected_id: "art-demo"
      }

      html = rendered_to_string(~H"<SidePanels.artifact_gallery_panel {assigns} />")

      assert html =~ "artifact-detail-art-demo"
      assert html =~ "artifact-embedded-preview-unavailable"
      assert html =~ "No embedded preview"
      refute html =~ ~s(id="artifact-embedded-preview")
    end

    test "renders load errors above the empty state" do
      assigns = %{artifact_projects: [], artifact_projects_error: "artifact load failed"}

      html = rendered_to_string(~H"<SidePanels.artifact_gallery_panel {assigns} />")

      assert html =~ "artifact-gallery-error"
      assert html =~ "artifact load failed"
      assert html =~ "No artifacts yet."
    end
  end
end
