defmodule DevIDE.Previews.DetectorTest do
  use ExUnit.Case, async: true

  alias DevIDE.Previews.Detector

  test "discovers full localhost URLs from terminal output" do
    assert [%{url: "http://localhost:5173/app", port: 5173, title: "localhost:5173"}] =
             Detector.discover("VITE ready at http://localhost:5173/app\n")
  end

  test "normalizes wildcard and loopback hosts to localhost" do
    candidates = Detector.discover("Local: http://0.0.0.0:3000\nNetwork: http://127.0.0.1:4000")

    assert Enum.any?(candidates, &(&1.url == "http://localhost:3000"))
    assert Enum.any?(candidates, &(&1.url == "http://localhost:4000"))
  end

  test "discovers bare host port hints and strips ANSI sequences" do
    assert [%{url: "http://localhost:8080", port: 8080}] =
             Detector.discover("\e[32mListening on localhost:8080\e[0m")
  end

  test "discovers https localhost URLs" do
    assert [%{url: "https://localhost:4443", port: 4443}] =
             Detector.discover("ready https://localhost:4443\n")
  end

  test "caps discovery at eight candidates" do
    ports = for p <- 3000..3010, do: "http://localhost:#{p}\n"
    assert length(Detector.discover(IO.iodata_to_binary(ports))) == 8
  end

  test "dedupes host:port hints when a full URL already matched the port" do
    text = "http://localhost:5173/app\nalso try localhost:5173\n"
    urls = Detector.discover(text) |> Enum.map(& &1.url)
    assert Enum.count(urls, &String.starts_with?(&1, "http://localhost:5173")) == 1
  end

  test "ignores non-local hosts and invalid input" do
    assert Detector.discover("prod at https://app.example.com:443\n") == []
    assert Detector.discover(nil) == []
  end
end
