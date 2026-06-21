defmodule DevIDE.Loops.Generator.AnthropicTest do
  use ExUnit.Case, async: false

  alias DevIDE.Loops.Generator.Anthropic

  setup do
    prev = Application.get_env(:dev_ide, DevIDE.Loops)
    prev_key = System.get_env("ANTHROPIC_API_KEY")
    System.delete_env("ANTHROPIC_API_KEY")

    on_exit(fn ->
      if prev,
        do: Application.put_env(:dev_ide, DevIDE.Loops, prev),
        else: Application.delete_env(:dev_ide, DevIDE.Loops)

      if prev_key, do: System.put_env("ANTHROPIC_API_KEY", prev_key)
    end)

    :ok
  end

  defp ctx do
    %{
      target: "test/x_test.exs:1",
      baseline_failures: [],
      feedback: "",
      prior_diff: nil,
      iteration: 1,
      root: nil
    }
  end

  defp configure(plug) do
    Application.put_env(:dev_ide, DevIDE.Loops,
      anthropic_api_key: "test-key",
      anthropic_req_options: [plug: plug, retry: false]
    )
  end

  test "short-circuits when no API key is configured" do
    Application.put_env(:dev_ide, DevIDE.Loops, anthropic_req_options: [])
    assert {:error, :missing_anthropic_api_key} = Anthropic.generate(ctx())
  end

  test "sends a well-formed Messages API request and returns the diff (fences stripped)" do
    test_pid = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:req, Jason.decode!(raw), Plug.Conn.get_req_header(conn, "x-api-key")})

      body =
        Jason.encode!(%{
          "content" => [
            %{"type" => "thinking", "thinking" => ""},
            %{
              "type" => "text",
              "text" => "```diff\n--- a/lib/foo.ex\n+++ b/lib/foo.ex\n@@\n-x\n+y\n```"
            }
          ],
          "stop_reason" => "end_turn"
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end

    configure(plug)

    assert {:ok, %{diff: diff, notes: notes}} = Anthropic.generate(ctx())
    assert diff == "--- a/lib/foo.ex\n+++ b/lib/foo.ex\n@@\n-x\n+y\n"
    assert notes == "stop_reason=end_turn"

    assert_received {:req, request, ["test-key"]}
    assert request["model"] == "claude-opus-4-8"
    assert request["thinking"] == %{"type" => "adaptive"}
    assert request["output_config"] == %{"effort" => "high"}
    assert request["max_tokens"] == 16_000
    assert [%{"role" => "user", "content" => content}] = request["messages"]
    assert content =~ "test/x_test.exs:1"
    assert request["system"] =~ "ONLY a unified git diff"
  end

  test "surfaces a non-200 response as an error" do
    plug = fn conn -> Plug.Conn.resp(conn, 500, ~s({"error":"overloaded"})) end
    configure(plug)
    assert {:error, {:anthropic_http, 500, _}} = Anthropic.generate(ctx())
  end
end
