defmodule DevIDE.Previews.CommandsTest do
  use ExUnit.Case, async: true

  alias DevIDE.Previews.Commands

  # A minimal workspace map. Only the pure / parse-error branches exercised
  # here ever touch it, and those branches short-circuit before any surface
  # discovery or preview-control IO, so its contents are never inspected.
  @workspace %{id: "ws-pure", metadata: %{}}

  describe "examples/0" do
    test "returns the documented preview command examples" do
      assert Commands.examples() == [
               "preview surfaces",
               "preview open app-local",
               "preview observe 1",
               "preview screenshot 1"
             ]
    end

    test "every example is a plain string starting with \"preview \"" do
      for example <- Commands.examples() do
        assert is_binary(example)
        assert String.starts_with?(example, "preview ")
      end
    end
  end

  describe "run/4 help branch" do
    test "bare \"preview\" returns help output with exit 0" do
      assert {:ok, result} = Commands.run(@workspace, "preview", ["preview"])

      assert %{
               status: "completed",
               line: "preview",
               argv: ["preview"],
               exit_code: 0,
               output: output,
               output_truncated: false
             } = result

      assert output =~ "Preview control commands:"
      assert output =~ "preview surfaces"
      assert output =~ "preview open <surface>"
      assert output =~ "preview observe <session_id>"
      assert output =~ "preview screenshot <id>"
      assert output =~ "preview click <id> <selector>"
      assert output =~ "preview navigate <id> <path>"
      assert output =~ "preview errors <id>"
      assert output =~ "preview close <id>"
    end
  end

  describe "run/4 unknown / malformed commands" do
    test "unknown subcommand returns {:error, :not_allowed}" do
      assert {:error, :not_allowed} =
               Commands.run(@workspace, "preview bogus", ["preview", "bogus"])
    end

    test "empty argv returns {:error, :not_allowed}" do
      assert {:error, :not_allowed} = Commands.run(@workspace, "", [])
    end

    test "non-preview command returns {:error, :not_allowed}" do
      assert {:error, :not_allowed} =
               Commands.run(@workspace, "ls -la", ["ls", "-la"])
    end

    test "too many args to open returns {:error, :not_allowed}" do
      assert {:error, :not_allowed} =
               Commands.run(@workspace, "preview open a b", ["preview", "open", "a", "b"])
    end

    test "missing surface for open returns {:error, :not_allowed}" do
      assert {:error, :not_allowed} =
               Commands.run(@workspace, "preview open", ["preview", "open"])
    end

    test "click without a selector returns {:error, :not_allowed}" do
      assert {:error, :not_allowed} =
               Commands.run(@workspace, "preview click 1", ["preview", "click", "1"])
    end

    test "navigate without a path returns {:error, :not_allowed}" do
      assert {:error, :not_allowed} =
               Commands.run(@workspace, "preview navigate 1", ["preview", "navigate", "1"])
    end
  end

  describe "run/4 invalid session id (parse_id short-circuit, pure)" do
    # A non-numeric session id fails parse_id/1 inside the `with`, so the
    # PreviewControl/PreviewTools IO call is never reached. The else clause
    # renders a failed result (exit_code 1) with `:invalid_session_id`.

    test "observe with non-numeric id reports failure without IO" do
      assert {:ok, result} =
               Commands.run(@workspace, "preview observe x", ["preview", "observe", "x"])

      assert %{status: "failed", exit_code: 1, argv: ["preview", "observe", "x"]} = result
      assert result.output =~ "Failed:"
      assert result.output =~ "invalid_session_id"
    end

    test "screenshot with non-numeric id reports failure" do
      assert {:ok, result} =
               Commands.run(@workspace, "preview screenshot z", ["preview", "screenshot", "z"])

      assert %{status: "failed", exit_code: 1, argv: ["preview", "screenshot", "z"]} = result
      assert result.output =~ "invalid_session_id"
    end

    test "click with non-numeric id reports failure" do
      assert {:ok, result} =
               Commands.run(@workspace, "preview click q #btn", [
                 "preview",
                 "click",
                 "q",
                 "#btn"
               ])

      assert %{
               status: "failed",
               exit_code: 1,
               argv: ["preview", "click", "q", "#btn"]
             } = result

      assert result.output =~ "invalid_session_id"
    end

    test "navigate with non-numeric id reports failure" do
      assert {:ok, result} =
               Commands.run(@workspace, "preview navigate q /home", [
                 "preview",
                 "navigate",
                 "q",
                 "/home"
               ])

      assert %{
               status: "failed",
               exit_code: 1,
               argv: ["preview", "navigate", "q", "/home"]
             } = result

      assert result.output =~ "invalid_session_id"
    end

    test "close with non-numeric id reports failure" do
      assert {:ok, result} =
               Commands.run(@workspace, "preview close nope", ["preview", "close", "nope"])

      assert %{status: "failed", exit_code: 1, argv: ["preview", "close", "nope"]} = result
      assert result.output =~ "invalid_session_id"
    end

    test "errors with non-numeric id reports failure" do
      assert {:ok, result} =
               Commands.run(@workspace, "preview errors nan", ["preview", "errors", "nan"])

      assert %{status: "failed", exit_code: 1, argv: ["preview", "errors", "nan"]} = result
      assert result.output =~ "invalid_session_id"
    end

    test "partially numeric id (trailing chars) is rejected by parse_id" do
      assert {:ok, result} =
               Commands.run(@workspace, "preview observe 12abc", [
                 "preview",
                 "observe",
                 "12abc"
               ])

      assert %{status: "failed", exit_code: 1} = result
      assert result.output =~ "invalid_session_id"
    end
  end

  describe "run/4 default opts" do
    test "actor_id defaults to \"terminal\" when opts omitted (help path still works)" do
      # The help branch ignores actor_id, but this confirms run/4 accepts the
      # 3-arity form (opts defaulted) without raising on the Keyword.get.
      assert {:ok, %{status: "completed"}} =
               Commands.run(@workspace, "preview", ["preview"])
    end
  end

  describe "run/4 guard clause" do
    # Launder bad args through opaque/1 so the compiler can't statically
    # narrow the type and emit a "expected map/list" warning.
    defp opaque(value), do: value

    test "raises FunctionClauseError when workspace is not a map" do
      assert_raise FunctionClauseError, fn ->
        Commands.run(opaque("not-a-map"), "preview", ["preview"])
      end
    end

    test "raises FunctionClauseError when argv is not a list" do
      assert_raise FunctionClauseError, fn ->
        Commands.run(@workspace, "preview", opaque("preview"))
      end
    end
  end
end
