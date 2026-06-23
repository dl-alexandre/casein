defmodule DevIDE.CLITest do
  # The runtimes memory adapter is a shared named process.
  use ExUnit.Case, async: false

  alias DevIDE.CLI
  alias DevIDE.Runtimes

  setup do
    Runtimes.clear()
    on_exit(fn -> Runtimes.clear() end)
    :ok
  end

  describe "run/1 dispatch" do
    test "rejects unknown commands with usage" do
      assert {:error, usage} = CLI.run(["bogus"])
      assert usage =~ "usage: jx runtimes"
    end

    test "rejects empty argv with usage" do
      assert {:error, usage} = CLI.run([])
      assert usage =~ "usage: jx runtimes"
    end

    test "dispatches runtimes with no subcommand to the runtimes usage" do
      assert {:error, usage} = CLI.run(["runtimes"])
      assert usage =~ "usage: jx runtimes ls|show <id>|expire <id>|cleanup [id]"
    end
  end

  describe "runtimes subcommands" do
    test "ls on an empty store returns only the header row" do
      assert {:ok, listing} = CLI.run(["runtimes", "ls"])
      assert listing == "id\tworkspace\tstatus\thost\trepo\tbranch\tisolation\tpath"
    end

    test "ls accepts workspace and status filters" do
      assert {:ok, listing} =
               CLI.run(["runtimes", "ls", "--workspace", "ws-none", "--status", "active"])

      assert [header] = String.split(listing, "\n")
      assert header =~ "id\tworkspace"
    end

    test "show errors for an unknown runtime id" do
      assert {:error, message} = CLI.run(["runtimes", "show", "rt-missing"])
      assert message == "runtime not found: rt-missing"
    end

    test "bulk cleanup on an empty store reports zero counts" do
      assert {:ok, "expired=0 cleaned=0"} = CLI.run(["runtimes", "cleanup"])
    end

    test "unknown runtimes subcommand returns the runtimes usage" do
      assert {:error, usage} = CLI.run(["runtimes", "frobnicate"])
      assert usage =~ "usage: jx runtimes ls|show <id>"
    end

    test "expire errors for an unknown runtime id" do
      assert {:error, "runtime not found: rt-missing"} =
               CLI.run(["runtimes", "expire", "rt-missing"])
    end

    test "cleanup errors for an unknown runtime id" do
      assert {:error, "runtime not found: rt-missing"} =
               CLI.run(["runtimes", "cleanup", "rt-missing"])
    end

    test "cleanup --stale routes to the bulk path instead of treating the flag as an id" do
      assert {:ok, "expired=0 cleaned=0"} = CLI.run(["runtimes", "cleanup", "--stale"])
    end
  end
end
