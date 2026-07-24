defmodule Mix.Tasks.Casein.Lan.Status do
  @moduledoc """
  Prints the current Casein LAN service status.

      mix dev_ide.lan.status
  """

  use Mix.Task
  use Boundary, classify_to: CaseinMix

  @shortdoc "Show Casein LAN readiness"

  @impl Mix.Task
  def run(args) do
    config = parse_config!(args)

    config
    |> Casein.Setup.LanRuntime.status()
    |> Casein.Setup.LanRuntime.print_status(Mix.shell())
  end

  defp parse_config!(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          backend_port: :integer,
          host: :string,
          ip: :string,
          listen_port: :integer,
          unit_dir: :string,
          workspace: :string,
          workspaces_root: :string
        ]
      )

    if invalid != [] do
      Mix.raise("invalid option(s): #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    end

    opts
    |> runtime_opts()
    |> Casein.Setup.LanRuntime.config()
  end

  defp runtime_opts(opts) do
    [
      backend_port: opts[:backend_port],
      lan_host: opts[:host],
      lan_ip: opts[:ip],
      listen_port: opts[:listen_port],
      unit_dir: opts[:unit_dir],
      workspace: opts[:workspace],
      workspaces_root: opts[:workspaces_root]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
