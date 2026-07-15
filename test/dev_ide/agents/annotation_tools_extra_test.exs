defmodule DevIDE.Agents.AnnotationToolsExtraTest do
  use DevIDE.DataCase, async: false

  alias DevIDE.Agents.AnnotationTools
  alias DevIDE.Annotations
  alias DevIDE.Audit

  setup do
    Audit.clear()
    :ok
  end

  describe "invoke/2 dispatch" do
    test "unknown tool returns {:error, :unknown_tool}" do
      assert {:error, :unknown_tool} = AnnotationTools.invoke("nope", %{})
      assert {:error, :unknown_tool} = AnnotationTools.invoke("annotation_delete", %{"x" => 1})
    end
  end

  describe "definitions/0" do
    test "exposes the two annotation tools with required workspace_id" do
      defs = AnnotationTools.definitions()
      names = Enum.map(defs, & &1.name)

      assert "annotation_list" in names
      assert "annotation_propose" in names
      assert length(defs) == 2

      for def <- defs do
        assert "workspace_id" in def.parameters.required
      end
    end
  end

  describe "annotation_list argument validation" do
    test "missing workspace_id returns {:error, :missing_workspace_id}" do
      assert {:error, :missing_workspace_id} = AnnotationTools.invoke("annotation_list", %{})
    end

    test "blank workspace_id returns {:error, :missing_workspace_id}" do
      assert {:error, :missing_workspace_id} =
               AnnotationTools.invoke("annotation_list", %{"workspace_id" => ""})
    end

    test "non-binary workspace_id returns {:error, :missing_workspace_id}" do
      assert {:error, :missing_workspace_id} =
               AnnotationTools.invoke("annotation_list", %{"workspace_id" => 123})
    end
  end

  describe "annotation_list empty + filters" do
    test "empty workspace returns count 0 and echoes workspace_id" do
      assert {:ok, %{workspace_id: "ws-empty", annotations: [], count: 0}} =
               AnnotationTools.invoke("annotation_list", %{"workspace_id" => "ws-empty"})
    end

    test "file_path filter narrows results" do
      {:ok, target} =
        Annotations.create("ws-filter", %{
          content: "On lib",
          author_type: :human,
          file_path: "lib/a.ex"
        })

      {:ok, _other} =
        Annotations.create("ws-filter", %{
          content: "On readme",
          author_type: :human,
          file_path: "README.md"
        })

      assert {:ok, %{annotations: [only], count: 1}} =
               AnnotationTools.invoke("annotation_list", %{
                 "workspace_id" => "ws-filter",
                 "file_path" => "lib/a.ex"
               })

      assert only.id == target.id
      assert only.file_path == "lib/a.ex"
    end

    test "invalid approval_state enum is ignored (treated as no filter)" do
      {:ok, _a} =
        Annotations.create("ws-badenum", %{
          content: "Note",
          author_type: :human,
          file_path: "lib/a.ex"
        })

      # "garbage" -> approval_state_atom/1 returns :error -> enum_arg yields nil ->
      # put_opt drops the key, so no approval_state filter is applied.
      assert {:ok, %{annotations: [_], count: 1}} =
               AnnotationTools.invoke("annotation_list", %{
                 "workspace_id" => "ws-badenum",
                 "approval_state" => "garbage"
               })
    end

    test "empty-string filters are dropped (string_arg returns nil)" do
      {:ok, _a} =
        Annotations.create("ws-blankfilter", %{
          content: "Note",
          author_type: :human,
          file_path: "lib/a.ex"
        })

      assert {:ok, %{annotations: [_], count: 1}} =
               AnnotationTools.invoke("annotation_list", %{
                 "workspace_id" => "ws-blankfilter",
                 "file_path" => "",
                 "session_id" => "",
                 "pane_id" => ""
               })
    end

    test "session_id and pane_id filters apply" do
      {:ok, match} =
        Annotations.create("ws-sp", %{
          content: "Has session+pane",
          author_type: :human,
          file_path: "lib/a.ex",
          session_id: "sess-1",
          pane_id: "pane-1"
        })

      {:ok, _miss} =
        Annotations.create("ws-sp", %{
          content: "Different session",
          author_type: :human,
          file_path: "lib/b.ex",
          session_id: "sess-2"
        })

      assert {:ok, %{annotations: [only], count: 1}} =
               AnnotationTools.invoke("annotation_list", %{
                 "workspace_id" => "ws-sp",
                 "session_id" => "sess-1",
                 "pane_id" => "pane-1"
               })

      assert only.id == match.id
      assert only.session_id == "sess-1"
      assert only.pane_id == "pane-1"
    end
  end

  describe "annotation_list limit coercion" do
    setup do
      for n <- 1..3 do
        {:ok, _} =
          Annotations.create("ws-limit", %{
            content: "Note #{n}",
            author_type: :human,
            file_path: "lib/a.ex"
          })
      end

      :ok
    end

    test "integer limit caps the result set" do
      assert {:ok, %{count: 2}} =
               AnnotationTools.invoke("annotation_list", %{
                 "workspace_id" => "ws-limit",
                 "limit" => 2
               })
    end

    test "string limit that parses is honored" do
      assert {:ok, %{count: 1}} =
               AnnotationTools.invoke("annotation_list", %{
                 "workspace_id" => "ws-limit",
                 "limit" => "1"
               })
    end

    test "unparseable string limit falls back to default" do
      assert {:ok, %{count: 3}} =
               AnnotationTools.invoke("annotation_list", %{
                 "workspace_id" => "ws-limit",
                 "limit" => "abc"
               })
    end

    test "non-positive integer limit falls back to default" do
      assert {:ok, %{count: 3}} =
               AnnotationTools.invoke("annotation_list", %{
                 "workspace_id" => "ws-limit",
                 "limit" => 0
               })
    end
  end

  describe "annotation_propose argument validation" do
    test "missing workspace_id returns {:error, :missing_workspace_id}" do
      assert {:error, :missing_workspace_id} =
               AnnotationTools.invoke("annotation_propose", %{
                 "content" => "x",
                 "author_type" => "agent_grok",
                 "file_path" => "lib/a.ex"
               })
    end

    test "missing content returns {:missing_field, \"content\"}" do
      assert {:error, {:missing_field, "content"}} =
               AnnotationTools.invoke("annotation_propose", %{
                 "workspace_id" => "ws-p",
                 "author_type" => "agent_grok",
                 "file_path" => "lib/a.ex"
               })
    end

    test "whitespace-only content is treated as missing" do
      assert {:error, {:missing_field, "content"}} =
               AnnotationTools.invoke("annotation_propose", %{
                 "workspace_id" => "ws-p",
                 "content" => "   ",
                 "author_type" => "agent_grok",
                 "file_path" => "lib/a.ex"
               })
    end

    test "missing author_type returns {:missing_field, \"author_type\"}" do
      assert {:error, {:missing_field, "author_type"}} =
               AnnotationTools.invoke("annotation_propose", %{
                 "workspace_id" => "ws-p",
                 "content" => "Some note",
                 "file_path" => "lib/a.ex"
               })
    end

    test "invalid author_type returns {:invalid_author_type, value}" do
      assert {:error, {:invalid_author_type, "robot"}} =
               AnnotationTools.invoke("annotation_propose", %{
                 "workspace_id" => "ws-p",
                 "content" => "Some note",
                 "author_type" => "robot",
                 "file_path" => "lib/a.ex"
               })
    end
  end

  describe "annotation_propose success paths" do
    test "valid visibility enum is parsed and persisted" do
      assert {:ok, %{annotation: annotation}} =
               AnnotationTools.invoke("annotation_propose", %{
                 "workspace_id" => "ws-vis",
                 "content" => "Private note",
                 "author_type" => "agent_claude",
                 "file_path" => "lib/a.ex",
                 "visibility" => "private"
               })

      assert annotation.visibility == "private"
      assert annotation.author_type == "agent_claude"
      assert annotation.approval_state == "pending"
    end

    test "non-file context anchor (terminal_range) is accepted and serialized" do
      assert {:ok, %{annotation: annotation}} =
               AnnotationTools.invoke("annotation_propose", %{
                 "workspace_id" => "ws-anchor",
                 "content" => "Terminal anchored",
                 "author_type" => "agent_grok",
                 "terminal_range" => %{"start" => 1, "end" => 5},
                 "metadata" => %{"k" => "v"}
               })

      assert annotation.terminal_range == %{"start" => 1, "end" => 5}
      assert annotation.metadata == %{"k" => "v"}
      assert annotation.file_path == nil
    end
  end

  describe "annotation_propose invalid changeset formatting" do
    test "missing context anchor returns formatted changeset errors with :base" do
      assert {:error, {:invalid_annotation, errors}} =
               AnnotationTools.invoke("annotation_propose", %{
                 "workspace_id" => "ws-noanchor",
                 "content" => "No anchor at all",
                 "author_type" => "agent_grok"
               })

      # format_changeset_errors interpolates opts; messages are flat strings keyed by :base.
      assert is_list(errors[:base])
      assert Enum.all?(errors[:base], &is_binary/1)
    end
  end
end
