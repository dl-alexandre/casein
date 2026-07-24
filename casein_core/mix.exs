defmodule CaseinCore.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/REPLACE_ME/casein_core"

  def project do
    [
      app: :casein_core,
      version: @version,
      elixir: "~> 1.15",
      compilers: [:boundary] ++ Mix.compilers(),
      deps: deps(),
      description:
        "Generic BEAM primitives for code-aware dev tooling: OS process " <>
          "streaming (erlexec), git worktree inspection, and MCP tool schemas.",
      package: package(),
      docs: docs(),
      name: "CaseinCore",
      source_url: @source_url
    ]
  end

  def application do
    # erlexec must be started; `git` is an external binary, not an OTP app.
    [extra_applications: [:logger] ++ if(native_windows?(), do: [], else: [:erlexec])]
  end

  defp deps do
    [
      {:erlexec, "~> 2.3", runtime: not native_windows?()},
      {:boundary, "~> 0.10", runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp native_windows? do
    match?({:win32, _}, :os.type()) or System.get_env("CASEIN_NATIVE_WINDOWS") in ~w(1 true)
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
