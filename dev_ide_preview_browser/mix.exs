defmodule DevIDEPreviewBrowser.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/REPLACE_ME/dev_ide_preview_browser"

  def project do
    [
      app: :dev_ide_preview_browser,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Standalone browser-runtime boundary for DevIDE preview control backends.",
      package: package(),
      docs: docs(),
      name: "DevIDEPreviewBrowser",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md)
    ]
  end

  defp docs do
    [main: "readme", extras: ["README.md"]]
  end
end
