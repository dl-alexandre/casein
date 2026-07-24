defmodule Casein.AnnotationsTest do
  use Casein.DataCase, async: false

  alias Casein.Annotations
  alias Casein.Annotations.Annotation
  alias Casein.Audit

  setup do
    Audit.clear()
    :ok
  end

  test "creates a workspace annotation linked to terminal context" do
    assert :ok = Annotations.subscribe("ws-1")

    assert {:ok, %Annotation{} = annotation} =
             Annotations.create("ws-1", %{
               content: "Check this failure before rerunning.",
               author_type: :human,
               session_id: "u-dev-tab",
               pane_id: "pane-1",
               terminal_range: %{"start_line" => 4, "end_line" => 7},
               actor_id: "dev"
             })

    assert annotation.workspace_id == "ws-1"
    assert annotation.visibility == :shared
    assert annotation.approval_state == :approved
    assert annotation.content == "Check this failure before rerunning."

    assert_receive {:annotation_created, ^annotation}

    assert [%{action: "annotation.created"} = event] = Audit.recent_for("ws-1", 5)
    assert event.actor_id == "dev"
    assert event.target_ref == annotation.id
    assert event.metadata["pane_id"] == "pane-1"
    assert event.metadata["approval_state"] == "approved"
  end

  test "requires content, author, workspace, and at least one context anchor" do
    assert {:error, changeset} =
             Annotations.create("ws-1", %{
               content: "   ",
               author_type: :human
             })

    assert %{content: [_ | _], base: [_ | _]} = errors_on(changeset)
  end

  test "lists and filters annotations for workspace" do
    {:ok, file_annotation} =
      Annotations.create("ws-1", %{
        content: "File note",
        author_type: :human,
        file_path: "lib/app.ex",
        file_range: %{"start_line" => 10, "end_line" => 12}
      })

    {:ok, preview_annotation} =
      Annotations.create("ws-1", %{
        content: "Preview note",
        author_type: :agent_grok,
        preview_id: Ecto.UUID.generate(),
        linked_entities: [%{"type" => "browser_dom", "selector" => "#submit"}]
      })

    {:ok, _other_workspace} =
      Annotations.create("ws-2", %{
        content: "Other workspace",
        author_type: :human,
        file_path: "README.md"
      })

    assert [^preview_annotation, ^file_annotation] = Annotations.list_for_workspace("ws-1")
    assert [^file_annotation] = Annotations.list_for_workspace("ws-1", file_path: "lib/app.ex")

    assert [^preview_annotation] =
             Annotations.list_for_workspace("ws-1", preview_id: preview_annotation.preview_id)
  end

  test "agent proposals default to pending approval" do
    assert {:ok, annotation} =
             Annotations.propose_from_agent(%{id: "ws-1"}, %{
               content: "Grok thinks this selector is stale.",
               author_type: :agent_grok,
               preview_id: Ecto.UUID.generate()
             })

    assert annotation.approval_state == :pending
    assert annotation.visibility == :shared
  end

  test "attaches existing annotation to a preview and broadcasts update" do
    {:ok, annotation} =
      Annotations.create("ws-1", %{
        content: "File issue visible in preview",
        author_type: :human,
        file_path: "lib/app.ex"
      })

    preview_id = Ecto.UUID.generate()
    assert :ok = Annotations.subscribe("ws-1")

    assert {:ok, updated} = Annotations.attach_to_preview(annotation, %{id: preview_id})

    assert updated.preview_id == preview_id
    assert_receive {:annotation_updated, ^updated}

    assert [%{action: "annotation.preview_attached"} | _] = Audit.recent_for("ws-1", 5)
  end

  test "approval helpers update agent-created annotations" do
    {:ok, annotation} =
      Annotations.propose_from_agent("ws-1", %{
        content: "Codex proposes this note.",
        author_type: :agent_codex,
        file_path: "test/app_test.exs"
      })

    assert {:ok, approved} = Annotations.approve(annotation, %{actor_id: "reviewer"})
    assert approved.approval_state == :approved

    assert {:ok, rejected} = Annotations.reject(approved, %{actor_id: "reviewer"})
    assert rejected.approval_state == :rejected

    assert [%{action: "annotation.rejected"}, %{action: "annotation.approved"} | _] =
             Audit.recent_for("ws-1", 5)
  end

  test "get/1 and get!/1 fetch by id and signal missing annotations" do
    {:ok, annotation} =
      Annotations.create("ws-1", %{
        content: "Fetch me",
        author_type: :human,
        file_path: "lib/app.ex"
      })

    assert {:ok, ^annotation} = Annotations.get(annotation.id)
    assert %Annotation{} = Annotations.get!(annotation.id)

    missing_id = Ecto.UUID.generate()
    assert {:error, :not_found} = Annotations.get(missing_id)
    assert_raise Ecto.NoResultsError, fn -> Annotations.get!(missing_id) end
  end

  test "string-keyed attrs are normalized and unknown keys are dropped" do
    assert {:ok, annotation} =
             Annotations.create("ws-1", %{
               "content" => "String keys work",
               "author_type" => "human",
               "file_path" => "lib/app.ex",
               "metadata" => %{"origin" => "api"},
               "bogus_key" => "must be ignored",
               "workspace_id" => "ws-spoofed"
             })

    assert annotation.content == "String keys work"
    assert annotation.author_type == :human
    assert annotation.file_path == "lib/app.ex"
    assert annotation.metadata == %{"origin" => "api"}
    # the workspace ref argument wins over any workspace_id in attrs
    assert annotation.workspace_id == "ws-1"
  end

  test "list_for_workspace honors limit and approval_state filters" do
    {:ok, first} =
      Annotations.create("ws-1", %{
        content: "First",
        author_type: :human,
        file_path: "lib/a.ex"
      })

    {:ok, second} =
      Annotations.create("ws-1", %{
        content: "Second",
        author_type: :human,
        file_path: "lib/b.ex"
      })

    {:ok, pending} =
      Annotations.propose_from_agent("ws-1", %{
        content: "Pending proposal",
        author_type: :agent_claude,
        file_path: "lib/c.ex"
      })

    assert [^pending] = Annotations.list_for_workspace("ws-1", limit: 1)

    assert [^pending] = Annotations.list_for_workspace("ws-1", approval_state: :pending)

    assert [^second, ^first] =
             Annotations.list_for_workspace("ws-1", approval_state: :approved)
  end

  test "list_for_workspace returns empty for unknown workspace" do
    assert [] = Annotations.list_for_workspace("ws-nothing-here")
  end
end
