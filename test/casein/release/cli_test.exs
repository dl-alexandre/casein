defmodule Casein.Release.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Casein.Release.CLI
  alias Casein.Release.Metadata

  setup do
    tmp = System.tmp_dir!() |> Path.join("casein-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    :ok =
      Metadata.write!(
        tmp,
        Metadata.build_for_assemble(
          revision: "abc123deadbeef",
          profile: "lan",
          target: "linux-x86_64"
        )
      )

    prev_root = System.get_env("CASEIN_RELEASE_ROOT")
    System.put_env("CASEIN_RELEASE_ROOT", tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)

      if prev_root,
        do: System.put_env("CASEIN_RELEASE_ROOT", prev_root),
        else: System.delete_env("CASEIN_RELEASE_ROOT")
    end)

    :ok
  end

  test "version prints human output" do
    output = capture_io(fn -> assert CLI.print_version([]) == :ok end)
    assert output =~ "casein"
    assert output =~ "abc123"
    assert output =~ "lan/linux-x86_64"
  end

  test "version --json prints metadata json" do
    output = capture_io(fn -> CLI.print_version(["--json"]) end)
    assert {:ok, map} = Jason.decode(output)
    assert map["revision"] == "abc123deadbeef"
    assert map["profile"] == "lan"
  end

  test "main_base64 decodes argv" do
    encoded = Base.encode64("version\0--json")

    output =
      capture_io(fn ->
        assert CLI.main_base64(encoded) == 0
      end)

    assert {:ok, map} = Jason.decode(output)
    assert map["revision"] == "abc123deadbeef"
  end

  test "main_base64 decodes newline argv from shell wrappers" do
    encoded = Base.encode64("version\n--json\n")

    output =
      capture_io(fn ->
        assert CLI.main_base64(encoded) == 0
      end)

    assert {:ok, map} = Jason.decode(output)
    assert map["revision"] == "abc123deadbeef"
  end
end
