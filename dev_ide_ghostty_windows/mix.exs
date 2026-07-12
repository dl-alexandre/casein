defmodule DevIDEGhosttyWindows.MixProject do
  use Mix.Project

  def project do
    [
      app: :ghostty,
      version: "0.4.9-windows.1",
      elixir: "~> 1.18",
      deps: []
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
