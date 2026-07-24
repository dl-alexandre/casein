defmodule Casein.AgentPromptTest do
  use Casein.TestCase, async: true

  alias Casein.AgentPrompt

  describe "chunks/2" do
    test "returns no chunks for empty text" do
      assert AgentPrompt.chunks("") == []
    end

    test "keeps text within the default line limit as one chunk" do
      prompt =
        1..AgentPrompt.default_max_lines_per_chunk()
        |> Enum.map_join("\n", &"line-#{&1}")

      assert AgentPrompt.chunks(prompt) == [prompt]
    end

    test "splits prompts into five-line chunks by default" do
      line_count = AgentPrompt.default_max_lines_per_chunk() * 2 + 3
      prompt = Enum.map_join(1..line_count, "\n", &"line-#{&1}")

      chunks = AgentPrompt.chunks(prompt)

      assert length(chunks) == 3
      assert chunks |> Enum.at(0) |> line_count() == 5
      assert chunks |> Enum.at(1) |> line_count() == 5
      assert chunks |> Enum.at(2) |> line_count() == 3
      assert Enum.join(chunks, "") == prompt
    end

    test "normalizes CRLF and bare CR before chunking" do
      assert AgentPrompt.chunks("alpha\r\nbeta\rgamma", max_lines_per_chunk: 2) == [
               "alpha\nbeta\n",
               "gamma"
             ]
    end

    test "preserves blank lines across chunk boundaries" do
      prompt = Enum.join(["one", "two", "", "four"], "\n")

      assert AgentPrompt.chunks(prompt, max_lines_per_chunk: 2) == [
               "one\ntwo\n",
               "\nfour"
             ]

      assert AgentPrompt.chunks(prompt, max_lines_per_chunk: 2) |> Enum.join("") == prompt
    end

    test "splits oversized single lines without changing sequential paste text" do
      prompt = "0123456789abcdef"

      assert chunks = AgentPrompt.chunks(prompt, max_bytes_per_chunk: 5)
      assert chunks == ["01234", "56789", "abcde", "f"]
      assert Enum.all?(chunks, &(byte_size(&1) <= 5))
      assert Enum.join(chunks, "") == prompt
    end

    test "keeps multibyte graphemes intact when byte splitting" do
      prompt = "aé🙂z"

      assert chunks = AgentPrompt.chunks(prompt, max_bytes_per_chunk: 3)
      assert Enum.join(chunks, "") == prompt
      assert Enum.all?(chunks, &String.valid?/1)
    end

    test "rejects invalid max line limits" do
      assert_raise ArgumentError, fn ->
        AgentPrompt.chunks("hello", max_lines_per_chunk: 0)
      end
    end

    test "rejects invalid max byte limits" do
      assert_raise ArgumentError, fn ->
        AgentPrompt.chunks("hello", max_bytes_per_chunk: 0)
      end
    end
  end

  describe "plan/2" do
    test "records submit intent without changing chunks" do
      assert %{
               chunks: ["alpha\nbeta"],
               max_lines_per_chunk: 5,
               max_bytes_per_chunk: 4_000,
               submit?: true
             } = AgentPrompt.plan("alpha\nbeta", submit: true)
    end

    test "does not submit by default" do
      assert %{submit?: false} = AgentPrompt.plan("alpha")
    end
  end

  describe "title_from_first_prompt/1" do
    test "returns nil for blank prompts" do
      assert AgentPrompt.title_from_first_prompt("\n \r\n") == nil
    end

    test "uses the first meaningful normalized line" do
      assert AgentPrompt.title_from_first_prompt("\r\n  Refactor   workspace handoff\n\nDetails") ==
               "Refactor workspace handoff"
    end

    test "strips obvious markdown and task-list prefixes" do
      assert AgentPrompt.title_from_first_prompt("## Fix MCP auth") == "Fix MCP auth"

      assert AgentPrompt.title_from_first_prompt("- Add previous session search") ==
               "Add previous session search"

      assert AgentPrompt.title_from_first_prompt("1. Add prompt chunking") ==
               "Add prompt chunking"

      assert AgentPrompt.title_from_first_prompt("[ ] Wire into terminal MCP") ==
               "Wire into terminal MCP"
    end

    test "truncates long titles" do
      title =
        "a"
        |> String.duplicate(AgentPrompt.max_title_length() + 10)
        |> AgentPrompt.title_from_first_prompt()

      assert String.length(title) == AgentPrompt.max_title_length()
      assert String.ends_with?(title, "...")
    end
  end

  defp line_count(chunk) do
    chunk
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> length()
  end
end
