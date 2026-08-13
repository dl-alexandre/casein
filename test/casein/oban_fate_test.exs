defmodule Casein.ObanFateTest do
  @moduledoc """
  #931: Oban stays declared for the planned retention sweeps. An empty
  poller was already ripped out (6813e690). The first `use Oban.Worker`
  under lib/ must also start Oban in Application — do not leave a
  declared-but-dead runner once a real job exists, and do not start an
  empty one before that.
  """
  use ExUnit.Case, async: true

  @mix Path.expand("../../mix.exs", __DIR__)
  @app Path.expand("../../lib/casein/application.ex", __DIR__)
  @worker Path.expand("../../lib/casein/signals/oban_worker.ex", __DIR__)

  test "oban stays in mix.exs next to the #931 decision comment" do
    mix = File.read!(@mix)

    assert mix =~ ~r/\{:oban,/
    assert mix =~ "#931"
    assert File.exists?(@worker)
  end

  test "first lib Oban worker must start Oban; empty poller must not" do
    lib_workers =
      Path.wildcard(Path.expand("../../lib/**/*.{ex,exs}", __DIR__))
      |> Enum.reject(&String.contains?(&1, "/signals/oban_"))
      |> Enum.filter(fn path ->
        contents = File.read!(path)

        Regex.match?(~r/use\s+(Oban\.Worker|Casein\.Signals\.ObanWorker)\b/, contents)
      end)

    app = File.read!(@app)
    started? = Regex.match?(~r/\{Oban[\s,}]/, app)

    if lib_workers == [] do
      refute started?,
             "Oban is started in Application with no lib/ worker — empty poller " <>
               "was already removed in 6813e690. Add a worker first, or drop the child."
    else
      assert started?,
             "lib/ has #{inspect(lib_workers)} using Oban.Worker but Application " <>
               "does not start Oban. Wire the supervisor child with the first job."
    end
  end
end
