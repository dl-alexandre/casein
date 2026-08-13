defmodule FlakeTailGuardTest do
  @moduledoc """
  #935: the flake tail is zeroed. A wildcard refute_receive or a bounded
  Process.sleep in test/ is a regression — partial removal is inert.
  """

  use ExUnit.Case, async: true

  test "test/ has no wildcard refute_receive" do
    needle = "refute_receive" <> " _unexpected"

    offenders =
      test_exs_files()
      |> Enum.filter(fn path ->
        path |> File.read!() |> String.contains?(needle)
      end)

    assert offenders == [], """
    #935: wildcard #{needle} is back. Match the specific unexpected
    protocol tag instead — a wildcard fails on stray background mail.

    #{Enum.join(offenders, "\n")}
    """
  end

  test "test/ has no bounded Process.sleep (infinity stubs are allowed)" do
    # Integer-literal sleeps only. Process.sleep(:infinity) is a never-reply
    # stub body and is not in scope.
    sleep_call = ~r/Process\.sleep\(\s*\d+/

    offenders =
      for path <- test_exs_files(),
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          Regex.match?(sleep_call, line) do
        "#{path}:#{n}: #{String.trim(line)}"
      end

    assert offenders == [], """
    #935: bounded Process.sleep is back. Use Casein.Test.Eventually.await/2
    (receive-after), not a shortened sleep — partial removal is inert.

    #{Enum.join(offenders, "\n")}
    """
  end

  defp test_exs_files do
    Path.wildcard("test/**/*.exs")
  end
end
