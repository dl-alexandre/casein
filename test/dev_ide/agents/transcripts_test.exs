defmodule Casein.Agents.TranscriptsTest do
  use ExUnit.Case, async: false

  alias Casein.Agents.Transcripts

  setup do
    previous_home = System.get_env("HOME")
    home = tmp_home!()

    on_exit(fn ->
      if previous_home,
        do: System.put_env("HOME", previous_home),
        else: System.delete_env("HOME")
    end)

    {:ok, home: home}
  end

  describe "allowed_path?/1" do
    test "accepts jsonl under ~/.claude", %{home: home} do
      path = claude_transcript!(home, "session-a.jsonl", "")
      assert Transcripts.allowed_path?(path)
    end

    test "accepts only the exact Grok updates.jsonl session filename", %{home: home} do
      path = grok_transcript!(home, "session-a", "")
      assert Transcripts.allowed_path?(path)

      other = Path.join(Path.dirname(path), "chat_history.jsonl")
      File.write!(other, "")
      refute Transcripts.allowed_path?(other)

      outside_sessions = Path.join([home, ".grok", "updates.jsonl"])
      File.mkdir_p!(Path.dirname(outside_sessions))
      File.write!(outside_sessions, "")
      refute Transcripts.allowed_path?(outside_sessions)
    end

    test "accepts isolated managed Grok sessions but rejects malformed leader roots", %{
      home: home
    } do
      leader_id = "0123456789abcdef01234567"

      managed =
        Path.join([
          home,
          ".devide",
          "grok-homes",
          leader_id,
          "sessions",
          "project",
          "session",
          "updates.jsonl"
        ])

      File.mkdir_p!(Path.dirname(managed))
      File.write!(managed, "")
      assert Transcripts.allowed_path?(managed)

      malformed = String.replace(managed, leader_id, "not-a-leader")
      File.mkdir_p!(Path.dirname(malformed))
      File.write!(malformed, "")
      refute Transcripts.allowed_path?(malformed)
    end

    test "rejects a symlinked Grok transcript", %{home: home} do
      outside = Path.join([home, "secret", "updates.jsonl"])
      File.mkdir_p!(Path.dirname(outside))
      File.write!(outside, "{}\n")

      path = Path.join([home, ".grok", "sessions", "project", "session", "updates.jsonl"])
      File.mkdir_p!(Path.dirname(path))
      File.ln_s!(outside, path)

      refute Transcripts.allowed_path?(path)
    end

    test "accepts a pending Grok transcript only through real parent directories", %{home: home} do
      pending = Path.join([home, ".grok", "sessions", "project", "pending", "updates.jsonl"])
      File.mkdir_p!(Path.dirname(pending))

      assert Casein.Agents.Transcripts.Grok.allowed_pending_path?(pending)

      outside = Path.join([home, "outside", "pending"])
      File.mkdir_p!(outside)
      linked = Path.join([home, ".grok", "sessions", "linked"])
      File.ln_s!(outside, linked)

      refute Casein.Agents.Transcripts.Grok.allowed_pending_path?(
               Path.join(linked, "updates.jsonl")
             )

      managed_pending =
        Path.join([
          home,
          ".devide/grok-homes",
          "0123456789abcdef01234567",
          "sessions",
          "project",
          "pending",
          "updates.jsonl"
        ])

      File.mkdir_p!(Path.dirname(managed_pending))
      assert Casein.Agents.Transcripts.Grok.allowed_pending_path?(managed_pending)
    end

    test "accepts jsonl under Casein auth profiles", %{home: home} do
      auth_root = Path.join([home, ".devide", "agent-auth"])
      Application.put_env(:casein, :agent_auth_profile_root, auth_root)

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

    test "normalizes Grok ACP chunks and tool calls", %{home: home} do
      path = grok_transcript!(home, "session-normalized", grok_fixture())

      assert {:ok, %{entries: entries, cursor: "grok:7", total_on_branch: 4}} =
               Transcripts.read(path, tail: 10)

      assert Enum.map(entries, & &1.role) == ["user", "assistant", "assistant", "assistant"]

      assert [user, narration, tool, answer] = entries
      assert user.text == "Inspect the file"
      assert user.timestamp == "2023-11-14T22:13:20.123Z"
      assert narration.text == "I'll inspect the file."
      assert narration.cursor == "grok:3"
      assert tool.tool_calls == [%{name: "Read", input_summary: "path=/tmp/show.ex"}]
      assert answer.text == "Done."
    end

    test "supports Grok incremental pulls, tail, native event cursors, and full text", %{
      home: home
    } do
      long_text = String.duplicate("x", 600)

      body =
        grok_fixture() <>
          grok_envelope(8, "agent_message_chunk", %{
            "content" => %{"type" => "text", "text" => long_text}
          })

      path = grok_transcript!(home, "session-incremental", body)

      assert {:ok, %{entries: entries, cursor: "grok:8"}} =
               Transcripts.read(path, since: "grok:4", tail: 10)

      assert Enum.map(entries, & &1.cursor) == ["grok:8"]
      assert entries |> List.first() |> Map.fetch!(:text) |> String.starts_with?("Done. ")
      assert String.length(List.last(entries).text) == 500

      assert {:ok, %{entries: [%{text: ^long_text}]}} =
               Transcripts.read(path, since: "grok-session-1-7", tail: 1, full_text: true)

      assert {:ok, %{entries: [last]}} = Transcripts.read(path, tail: 1)
      assert last.cursor == "grok:8"
    end

    test "uses descriptive orphan tool updates without duplicating normal updates", %{home: home} do
      body =
        grok_envelope(1, "tool_call_update", %{
          "toolCallId" => "orphan",
          "title" => "Execute tests",
          "rawInput" => %{"command" => "mix test"}
        }) <>
          grok_envelope(2, "tool_call_update", %{
            "toolCallId" => "orphan",
            "status" => "completed"
          })

      path = grok_transcript!(home, "session-orphan", body)

      assert {:ok, %{entries: [entry], total_on_branch: 1}} = Transcripts.read(path)

      assert entry.tool_calls == [
               %{name: "Execute tests", input_summary: "command=mix test"}
             ]
    end

    test "accepts legacy raw ACP notifications and skips a torn trailing record", %{home: home} do
      body =
        Jason.encode!(%{
          "sessionId" => "legacy-session",
          "update" => %{
            "sessionUpdate" => "user_message_chunk",
            "content" => %{"type" => "text", "text" => "legacy prompt"}
          }
        }) <> "\n{\"sessionId\":\"torn"

      path = grok_transcript!(home, "session-legacy", body)

      assert {:ok,
              %{
                entries: [%{role: "user", text: "legacy prompt", cursor: "grok:1"}],
                cursor: "grok:1",
                total_on_branch: 1
              }} = Transcripts.read(path)
    end

    test "filters rewound Grok turns from the active branch", %{home: home} do
      body =
        grok_envelope(1, "user_message_chunk", %{
          "content" => %{"type" => "text", "text" => "keep"},
          "_meta" => %{"promptIndex" => 0}
        }) <>
          grok_envelope(2, "agent_message_chunk", %{
            "content" => %{"type" => "text", "text" => "kept answer"}
          }) <>
          grok_envelope(3, "user_message_chunk", %{
            "content" => %{"type" => "text", "text" => "discard"},
            "_meta" => %{"promptIndex" => 1}
          }) <>
          grok_envelope(4, "agent_message_chunk", %{
            "content" => %{"type" => "text", "text" => "discarded answer"}
          }) <>
          grok_envelope(
            5,
            "rewind_marker",
            %{"target_prompt_index" => 1},
            "_x.ai/session/update"
          ) <>
          grok_envelope(6, "user_message_chunk", %{
            "content" => %{"type" => "text", "text" => "replacement"},
            "_meta" => %{"promptIndex" => 1}
          })

      path = grok_transcript!(home, "session-rewind", body)

      assert {:ok, %{entries: entries, cursor: "grok:6", total_on_branch: 3}} =
               Transcripts.read(path, tail: 10)

      assert Enum.map(entries, & &1.text) == ["keep", "kept answer", "replacement"]
    end

    test "Grok hints and final answers use normalized entries", %{home: home} do
      path = grok_transcript!(home, "session-helpers", grok_fixture())

      assert Transcripts.activity_hint(path) == "reading show.ex"
      assert Transcripts.final_assistant_message(path) == "Done."
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

  defp grok_transcript!(home, session_id, body) do
    path =
      Path.join([
        home,
        ".grok",
        "sessions",
        "%2Ftmp%2Fdevide-test",
        session_id,
        "updates.jsonl"
      ])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  defp grok_fixture do
    Path.join([File.cwd!(), "test", "fixtures", "agents", "grok_updates.jsonl"])
    |> File.read!()
  end

  defp grok_envelope(line, tag, fields, method \\ "session/update") do
    update = Map.put(fields, "sessionUpdate", tag)

    Jason.encode!(%{
      "timestamp" => 1_700_000_000 + line,
      "method" => method,
      "params" => %{
        "sessionId" => "grok-session-1",
        "update" => update,
        "_meta" => %{
          "eventId" => "grok-session-1-#{line}",
          "agentTimestampMs" => 1_700_000_000_000 + line
        }
      }
    }) <> "\n"
  end

  defp tmp_home! do
    root = System.get_env("CASEIN_TEST_TMPDIR") || System.tmp_dir!()
    home = Path.join(root, "devide-transcripts-#{System.unique_integer([:positive])}")
    File.rm_rf!(home)
    File.mkdir_p!(home)
    System.put_env("HOME", home)
    on_exit(fn -> File.rm_rf!(home) end)
    home
  end
end
