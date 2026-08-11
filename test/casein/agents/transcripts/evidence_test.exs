defmodule Casein.Agents.Transcripts.EvidenceTest do
  use ExUnit.Case, async: true

  alias Casein.Agents.Transcripts.Evidence

  @silence Evidence.default_silence_seconds()

  setup do
    root = Path.join(System.tmp_dir!(), "evidence-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  describe "absence vs. failure" do
    test "a missing transcript is an error, not a waiting agent" do
      assert {:error, :enoent} = Evidence.observe("/definitely/not/here.jsonl")
    end

    test "a directory where a transcript should be is an error", %{root: root} do
      assert {:error, :not_a_file} = Evidence.observe(root)
    end

    test "an empty transcript reads successfully with no shape", %{root: root} do
      path = write!(root, [])

      assert {:ok, observation} = Evidence.observe(path, now: later())

      # Distinguishable from {:error, _}: the tail was read, it just held no turn.
      assert observation.last_shape == nil
      assert observation.lines_scanned == 0
      # An empty read is not a finished agent.
      assert Evidence.classify(observation) == :unknown
    end

    test "a transcript of only bookkeeping lines has no shape", %{root: root} do
      path =
        write!(root, [
          %{"type" => "summary", "summary" => "prior session"},
          %{"type" => "system", "content" => "hook fired"}
        ])

      assert {:ok, observation} = Evidence.observe(path, now: later())
      assert observation.last_shape == nil
      assert Evidence.classify(observation) == :unknown
    end
  end

  describe "shape at the tail" do
    test "assistant prose then silence is the agent waiting on a human", %{root: root} do
      path =
        write!(root, [
          user("run the migration"),
          assistant_tool_call("Bash"),
          tool_result(),
          assistant_prose("Done — want me to push?")
        ])

      assert {:ok, observation} = Evidence.observe(path, now: later())

      assert observation.last_shape == :assistant_prose
      assert Evidence.classify(observation) == :awaiting_input
    end

    test "an outstanding tool call is working, however long it has been quiet", %{root: root} do
      path = write!(root, [assistant_prose("thinking"), assistant_tool_call("Bash")])

      assert {:ok, observation} = Evidence.observe(path, now: later(3_600))

      assert observation.last_shape == :tool_call
      # Deliberately not :awaiting_input — a long `mix test` is not a question.
      assert Evidence.classify(observation) == :working
    end

    test "a tool result is working, not a user turn", %{root: root} do
      path = write!(root, [assistant_tool_call("Read"), tool_result()])

      assert {:ok, observation} = Evidence.observe(path, now: later())

      assert observation.last_shape == :tool_result
      assert Evidence.classify(observation) == :working
    end

    test "a tool result carrying toolUseResult is recognized without content blocks", %{
      root: root
    } do
      entry = %{
        "type" => "user",
        "toolUseResult" => %{"stdout" => "ok"},
        "message" => %{"role" => "user", "content" => "tool output"}
      }

      path = write!(root, [assistant_tool_call("Bash"), entry])

      assert {:ok, observation} = Evidence.observe(path, now: later())
      assert observation.last_shape == :tool_result
    end

    test "a genuine user turn at the tail is working, not waiting", %{root: root} do
      path = write!(root, [assistant_prose("done"), user("now do the other thing")])

      assert {:ok, observation} = Evidence.observe(path, now: later())

      assert observation.last_shape == :user
      assert Evidence.classify(observation) == :working
    end

    test "a subagent tail means the main agent is inside a Task", %{root: root} do
      # The trap: a subagent's closing prose looks exactly like the main agent
      # signing off, and would strand a busy pane in the attention list.
      sidechain = Map.put(assistant_prose("subagent finished"), "isSidechain", true)
      path = write!(root, [assistant_tool_call("Task"), sidechain])

      assert {:ok, observation} = Evidence.observe(path, now: later())

      assert observation.last_shape == :sidechain
      assert Evidence.classify(observation) == :working
    end

    test "an assistant turn with no text and no tool call is still mid-turn", %{root: root} do
      thinking = %{
        "type" => "assistant",
        "message" => %{
          "role" => "assistant",
          "content" => [%{"type" => "thinking", "thinking" => "hmm"}]
        }
      }

      path = write!(root, [user("go"), thinking])

      assert {:ok, observation} = Evidence.observe(path, now: later())
      assert observation.last_shape == :tool_call
      assert Evidence.classify(observation) == :working
    end

    test "malformed trailing lines are skipped rather than read as absence", %{root: root} do
      path = write!(root, [assistant_prose("waiting on you")])
      File.write!(path, "{\"type\": \"assistant\", truncated", [:append])

      assert {:ok, observation} = Evidence.observe(path, now: later())

      assert observation.last_shape == :assistant_prose
      assert Evidence.classify(observation) == :awaiting_input
    end
  end

  describe "silence gates the verdict" do
    test "a freshly written transcript is working and is not read at all", %{root: root} do
      path = write!(root, [assistant_prose("Done — want me to push?")])

      assert {:ok, observation} = Evidence.observe(path)

      assert observation.silent_for_seconds < @silence
      # The tail is a moving target; refusing to read it is the point.
      assert observation.last_shape == nil
      assert observation.lines_scanned == 0
      assert Evidence.classify(observation) == :working
    end

    test "the silence threshold is caller-tunable", %{root: root} do
      path = write!(root, [assistant_prose("Done")])

      assert {:ok, observation} = Evidence.observe(path, silence_seconds: 0)

      assert observation.last_shape == :assistant_prose
      assert Evidence.classify(observation, silence_seconds: 0) == :awaiting_input
    end

    test "classify honours a threshold above the observed silence", %{root: root} do
      path = write!(root, [assistant_prose("Done")])

      assert {:ok, observation} = Evidence.observe(path, silence_seconds: 0, now: later(60))

      assert observation.silent_for_seconds >= 60
      assert Evidence.classify(observation, silence_seconds: 3_600) == :working
    end
  end

  describe "cost" do
    test "only the tail of a large transcript is read", %{root: root} do
      # A long session ahead of the turn that matters. Parsing this whole file on
      # every gather cycle is what the tail read exists to avoid.
      filler = List.duplicate(tool_result(), 4_000)
      path = write!(root, filler ++ [assistant_prose("waiting on you")])

      assert File.stat!(path).size > Evidence.tail_bytes()
      assert {:ok, observation} = Evidence.observe(path, now: later())

      assert observation.truncated?
      assert observation.last_shape == :assistant_prose
      assert observation.lines_scanned == 1
    end
  end

  ## Fixtures

  defp write!(root, entries) do
    path = Path.join(root, "session-#{System.unique_integer([:positive])}.jsonl")
    body = Enum.map_join(entries, "", &(Jason.encode!(&1) <> "\n"))
    File.write!(path, body)
    path
  end

  # The transcript's own mtime is "now"; tests move the observer forward instead
  # of backdating files, so silence is exercised without touching the clock.
  defp later(seconds \\ @silence + 1) do
    DateTime.add(DateTime.utc_now(), seconds, :second)
  end

  defp user(text) do
    %{"type" => "user", "message" => %{"role" => "user", "content" => text}}
  end

  defp assistant_prose(text) do
    %{
      "type" => "assistant",
      "message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => text}]}
    }
  end

  defp assistant_tool_call(name) do
    %{
      "type" => "assistant",
      "message" => %{
        "role" => "assistant",
        "content" => [%{"type" => "tool_use", "name" => name, "input" => %{}}]
      }
    }
  end

  defp tool_result do
    %{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => [%{"type" => "tool_result", "content" => "ok"}]
      }
    }
  end
end
