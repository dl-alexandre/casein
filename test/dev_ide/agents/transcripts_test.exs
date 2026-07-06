defmodule DevIDE.Agents.TranscriptsTest do
  use ExUnit.Case, async: false

  alias DevIDE.Agents.Transcripts

  setup do
    home = tmp_home!()
    on_exit(fn -> System.put_env("HOME", home) end)
    {:ok, home: home}
  end

  describe "allowed_path?/1" do
    test "accepts jsonl under ~/.claude", %{home: home} do
      path = claude_transcript!(home, "session-a.jsonl", "")
      assert Transcripts.allowed_path?(path)
    end

    test "accepts jsonl under DevIDE auth profiles", %{home: home} do
      auth_root = Path.join([home, ".devide", "agent-auth"])
      Application.put_env(:dev_ide, :agent_auth_profile_root, auth_root)

      path =
        Path.join([
          auth_root,
          "profiles",
          "alice",
          "claude",
          "projects",
          "proj",
          "session-b.jsonl"
        ])

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{}\n")

      assert Transcripts.allowed_path?(path)
    end

    test "rejects paths outside allowed roots", %{home: home} do
      path = Path.join([home, "secret", "notes.jsonl"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{}\n")
      refute Transcripts.allowed_path?(path)
    end

    test "rejects non-jsonl extensions", %{home: home} do
      path = Path.join([home, ".claude", "projects", "x", "session.txt"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "nope")
      refute Transcripts.allowed_path?(path)
    end
  end

  describe "read/2" do
    test "reconstructs the active branch and normalizes entries", %{home: home} do
      path = claude_transcript!(home, "branch.jsonl", sample_transcript())

      assert {:ok, %{entries: entries, cursor: "a2", total_on_branch: 4}} =
               Transcripts.read(path, tail: 10)

      assert Enum.map(entries, & &1.role) == ["user", "assistant", "user", "assistant"]

      [_, assistant | _] = entries
      assert assistant.text == "I'll read that file."
      assert [%{name: "Read", input_summary: input}] = assistant.tool_calls
      assert input =~ "file_path="
    end

    test "supports incremental pulls via since", %{home: home} do
      path = claude_transcript!(home, "since.jsonl", sample_transcript())

      assert {:ok, %{entries: first}} = Transcripts.read(path, tail: 10)
      assert length(first) == 4

      assert {:ok, %{entries: rest}} = Transcripts.read(path, since: "a1", tail: 10)
      assert Enum.map(rest, & &1.cursor) == ["u2", "a2"]
    end

    test "activity_hint surfaces the latest tool target", %{home: home} do
      path = claude_transcript!(home, "hint.jsonl", sample_transcript())

      assert Transcripts.activity_hint(path) == "reading show.ex"
    end

    test "final_assistant_message returns the last assistant text", %{home: home} do
      path = claude_transcript!(home, "answer.jsonl", sample_transcript())

      assert Transcripts.final_assistant_message(path) == "Done."
    end

    test "tails to the requested number of entries", %{home: home} do
      path = claude_transcript!(home, "tail.jsonl", sample_transcript())

      assert {:ok, %{entries: entries}} = Transcripts.read(path, tail: 2)
      assert Enum.map(entries, & &1.cursor) == ["u2", "a2"]
    end
  end

  defp sample_transcript do
    [
      user_entry("u1", nil, "Fix the bug", "2026-07-06T10:00:00.000Z"),
      assistant_entry(
        "a1",
        "u1",
        "I'll read that file.",
        [
          %{
            "type" => "tool_use",
            "id" => "tool-1",
            "name" => "Read",
            "input" => %{"file_path" => "/tmp/show.ex"}
          }
        ],
        "2026-07-06T10:00:01.000Z"
      ),
      user_entry("u2", "a1", "thanks", "2026-07-06T10:00:02.000Z"),
      assistant_entry("a2", "u2", "Done.", [], "2026-07-06T10:00:03.000Z"),
      assistant_entry("fork", "u1", "stale fork", [], "2026-07-06T09:59:00.000Z")
    ]
    |> Enum.map_join("\n", &Jason.encode!/1)
    |> Kernel.<>("\n")
  end

  defp user_entry(uuid, parent, text, timestamp) do
    %{
      "uuid" => uuid,
      "parentUuid" => parent,
      "type" => "user",
      "timestamp" => timestamp,
      "message" => %{"role" => "user", "content" => text}
    }
  end

  defp assistant_entry(uuid, parent, text, blocks, timestamp) do
    content =
      [%{"type" => "text", "text" => text}] ++ blocks

    %{
      "uuid" => uuid,
      "parentUuid" => parent,
      "type" => "assistant",
      "timestamp" => timestamp,
      "message" => %{"role" => "assistant", "content" => content}
    }
  end

  defp claude_transcript!(home, name, body) do
    path = Path.join([home, ".claude", "projects", "test-project", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  defp tmp_home! do
    root = System.get_env("DEV_IDE_TEST_TMPDIR") || System.tmp_dir!()
    home = Path.join(root, "devide-transcripts-#{System.unique_integer([:positive])}")
    File.rm_rf!(home)
    File.mkdir_p!(home)
    System.put_env("HOME", home)
    on_exit(fn -> File.rm_rf!(home) end)
    home
  end
end
