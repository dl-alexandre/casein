defmodule Mix.Tasks.Casein.Lan.Setup do
  @moduledoc """
  Generates a trusted local development certificate for Casein LAN mode.

      mix casein.lan.setup
      mix casein.lan.setup --hostname workstation --hosts workstation.home,devide.test
      mix casein.lan.setup --no-install-ca

  The task requires `mkcert` on PATH. By default it runs `mkcert -install`
  before generating `priv/cert/devide-lan.pem` and
  `priv/cert/devide-lan-key.pem`.
  """

  use Mix.Task
  use Boundary, classify_to: CaseinMix

  @shortdoc "Generate mkcert certificates for LAN HTTPS development"

  @default_cert_dir "priv/cert"
  @cert_filename "devide-lan.pem"
  @key_filename "devide-lan-key.pem"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          cert_dir: :string,
          hostname: :string,
          hosts: :string,
          install_ca: :boolean,
          force: :boolean
        ]
      )

    if invalid != [] do
      Mix.raise("invalid option(s): #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    end

    mkcert = System.find_executable("mkcert") || missing_mkcert!()
    cert_dir = opts[:cert_dir] || @default_cert_dir
    certfile = Path.join(cert_dir, @cert_filename)
    keyfile = Path.join(cert_dir, @key_filename)
    hostname = opts[:hostname] || short_hostname()
    hosts = hosts_for(hostname, opts[:hosts])

    File.mkdir_p!(cert_dir)

    if Keyword.get(opts, :install_ca, true) do
      install_ca(mkcert)
    end

    if certs_exist?(certfile, keyfile) and not opts[:force] do
      Mix.shell().info("LAN certificate already exists. Use --force to regenerate it.")
    else
      run_mkcert!(
        mkcert,
        ["-cert-file", certfile, "-key-file", keyfile | hosts]
      )
    end

    print_next_steps(hostname, hosts, certfile, keyfile)
  end

  defp install_ca(mkcert) do
    case run_mkcert(mkcert, ["-install"]) do
      {:ok, output} ->
        print_output(output)

      {:error, status, output} ->
        Mix.shell().error("""
        mkcert -install failed with status #{status}; continuing with certificate generation.

        Run this directly in an interactive shell if you want this host to trust
        the local CA:

          mkcert -install

        mkcert output:
        #{String.trim(output)}
        """)
    end
  end

  defp missing_mkcert! do
    Mix.raise("""
    mkcert was not found on PATH.

    Install mkcert first, then rerun this task:

      Arch:   sudo pacman -S mkcert nss
      macOS:  brew install mkcert nss
      Ubuntu: sudo apt install mkcert libnss3-tools
    """)
  end

  defp short_hostname do
    Casein.Setup.LocalDomain.short_hostname()
  end

  defp hosts_for(hostname, extra_hosts) do
    local_hostname = Casein.Setup.LocalDomain.mdns_hostname()

    extra_hosts =
      case extra_hosts do
        value when is_binary(value) ->
          value
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)

        _ ->
          []
      end

    local_domain = System.get_env("CASEIN_LOCAL_DOMAIN") || "devide.test"

    [
      "localhost",
      "127.0.0.1",
      "::1",
      hostname,
      local_domain,
      local_hostname,
      "devide.local"
      | extra_hosts
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp certs_exist?(certfile, keyfile) do
    File.exists?(certfile) and File.exists?(keyfile)
  end

  defp run_mkcert!(mkcert, args) do
    case run_mkcert(mkcert, args) do
      {:ok, output} ->
        print_output(output)

      {:error, status, output} ->
        Mix.raise("mkcert failed with status #{status}:\n#{output}")
    end
  end

  defp run_mkcert(mkcert, args) do
    Mix.shell().info(["$", " ", mkcert, " ", Enum.join(args, " ")])

    case System.cmd(mkcert, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, status, output}
    end
  end

  defp print_output(""), do: :ok
  defp print_output(output), do: Mix.shell().info(output)

  defp print_next_steps(hostname, hosts, certfile, keyfile) do
    lan_hostname =
      System.get_env("CASEIN_LAN_HOST") ||
        Enum.find(hosts, &(&1 == Casein.Setup.LocalDomain.mdns_hostname())) ||
        Enum.find(hosts, &String.ends_with?(&1, ".local")) ||
        "#{hostname}.local"

    host_local_domain = System.get_env("CASEIN_LOCAL_DOMAIN") || "devide.test"

    Mix.shell().info("""

    LAN HTTPS certificate is ready.

    Hosts:
      #{Enum.join(hosts, "\n  ")}

    Files:
      cert: #{certfile}
      key:  #{keyfile}

    Start Casein in LAN mode:

      CASEIN_LAN=true mise exec -- mix phx.server

    This opens the default home workspace at `/`. To create/check the home
    workspace and browser trust helpers first:

      mise exec -- mix casein.doctor --fix

    Open:

      https://#{lan_hostname}:4443/

    Same-host fallback after doctor updates /etc/hosts:

      https://#{host_local_domain}:4443/
    """)
  end
end
