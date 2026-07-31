defmodule Mix.Tasks.Casein.Doctor do
  @moduledoc """
  Checks the local Casein development setup and can fix safe local defaults.

      mix casein.doctor
      mix casein.doctor --fix
      mix casein.doctor --fix --edge
      mix casein.doctor --fix --insecure-http
      mix casein.doctor --fix --hosts 192.168.1.240
      mix casein.doctor --fix --local-domain casein.test

  With `--fix`, the task creates the configured default workspace directory,
  generates missing LAN certificates with `mkcert`, and imports the mkcert root
  into the user's NSS database when `certutil` is available. It also prepares a
  local hosts-file domain. Privileged changes are attempted only with an
  existing sudo ticket; otherwise the task writes a prepared file and prints the
  exact `sudo install ...` command.
  """

  use Mix.Task
  use Boundary, classify_to: CaseinMix

  @shortdoc "Check and repair local Casein setup"

  @certfile "priv/cert/casein-lan.pem"
  @keyfile "priv/cert/casein-lan-key.pem"
  @default_hosts_file "/etc/hosts"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          fix: :boolean,
          hosts: :string,
          workspace: :string,
          workspaces_root: :string,
          local_domain: :string,
          lan_ip: :string,
          hosts_file: :string,
          lan_host: :string,
          edge: :boolean,
          edge_port: :integer,
          insecure_http: :boolean,
          insecure_http_port: :integer,
          install_ca: :boolean,
          force_certs: :boolean
        ]
      )

    if invalid != [] do
      Mix.raise("invalid option(s): #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    end

    fix? = Keyword.get(opts, :fix, false)
    workspace = opts[:workspace] || System.get_env("CASEIN_DEFAULT_WORKSPACE") || "home"

    root =
      opts[:workspaces_root] || System.get_env("CASEIN_WORKSPACES_ROOT") ||
        "/tmp/casein_workspaces"

    http_port = env_int("PORT") || 4000
    https_port = env_int("CASEIN_LAN_HTTPS_PORT") || 4443
    edge_port = Keyword.get(opts, :edge_port) || env_int("CASEIN_LAN_EDGE_PORT") || 443

    insecure_http_port =
      Keyword.get(opts, :insecure_http_port) || env_int("CASEIN_LAN_INSECURE_HTTP_PORT") || 80

    local_domain = opts[:local_domain] || Casein.Setup.LocalDomain.default_domain()

    lan_host =
      opts[:lan_host] || System.get_env("CASEIN_LAN_HOST") ||
        Casein.Setup.LocalDomain.mdns_hostname()

    lan_ip = opts[:lan_ip] || Casein.Setup.LocalDomain.default_ip()
    hosts_file = opts[:hosts_file] || @default_hosts_file
    edge? = Keyword.get(opts, :edge, false) or truthy_env?("CASEIN_LAN_EDGE")

    insecure_http? =
      Keyword.get(opts, :insecure_http, false) or truthy_env?("CASEIN_LAN_INSECURE_HTTP")

    Mix.shell().info("Casein doctor\n")

    check_home_workspace(root, workspace, fix?)
    check_mkcert(opts, fix?)
    check_certificates(opts, local_domain, lan_host, lan_ip, fix?)
    check_local_domain(local_domain, lan_ip, hosts_file, fix?)
    check_host_trust()
    check_nss_trust(fix?)

    check_firewall(
      port_for_firewall(insecure_http?, edge?, insecure_http_port, edge_port, https_port)
    )

    check_lan_edge(edge?, edge_port, https_port, lan_host, fix?)
    check_insecure_http_edge(insecure_http?, insecure_http_port, http_port, lan_host, fix?)
    check_node_assets()
    check_database(fix?)
    check_access_endpoints()

    Mix.shell().info(
      quick_start_message(%{
        edge?: edge?,
        https_port: https_port,
        insecure_http?: insecure_http?,
        lan_host: lan_host,
        local_domain: local_domain,
        root: root,
        workspace: workspace
      })
    )
  end


  defp check_access_endpoints do
    Mix.shell().info("")

    entries =
      Casein.Access.Endpoints.advertised()
      |> Enum.map(fn endpoint ->
        {endpoint, Casein.Access.Probe.reachable?(endpoint)}
      end)

    entries
    |> Casein.Access.Endpoints.doctor_lines()
    |> Enum.each(&Mix.shell().info/1)
  end

  defp check_home_workspace(root, workspace, fix?) do
    path = Path.expand(Path.join(root, workspace))

    cond do
      unsafe_workspace_name?(workspace) ->
        bad("home workspace", "invalid workspace name #{inspect(workspace)}")

      File.dir?(path) ->
        ok("home workspace", path)

      fix? ->
        File.mkdir_p!(path)
        ok("home workspace", "created #{path}")

      true ->
        warn("home workspace", "missing #{path}; run with --fix to create it")
    end
  end

  defp check_mkcert(_opts, _fix?) do
    if System.find_executable("mkcert") do
      ok("mkcert", "installed")
    else
      bad("mkcert", "missing; Arch: sudo pacman -S mkcert nss")
    end
  end

  defp check_certificates(opts, local_domain, lan_host, lan_ip, fix?) do
    certfile = Path.expand(@certfile)
    keyfile = Path.expand(@keyfile)

    cond do
      File.exists?(certfile) and File.exists?(keyfile) and
        cert_covers?(certfile, local_domain) and cert_covers?(certfile, lan_host) ->
        ok("LAN certificate", "#{certfile}")

      fix? and System.find_executable("mkcert") ->
        force? = File.exists?(certfile) or File.exists?(keyfile)
        args = setup_args(opts, local_domain, lan_host, lan_ip, force?)
        Mix.shell().info(["  ", "$ mix casein.lan.setup ", Enum.join(args, " ")])
        Mix.Task.rerun("casein.lan.setup", args)

      true ->
        warn("LAN certificate", "missing or does not cover #{local_domain}; run doctor --fix")
    end
  end

  defp setup_args(opts, local_domain, lan_host, lan_ip, force?) do
    args =
      if Keyword.get(opts, :install_ca, false) do
        []
      else
        ["--no-install-ca"]
      end

    args =
      if hosts = opts[:hosts] do
        args ++ ["--hosts", join_hosts([hosts, local_domain, lan_host, lan_ip])]
      else
        args ++ ["--hosts", join_hosts([local_domain, lan_host, lan_ip])]
      end

    if force? or Keyword.get(opts, :force_certs, false), do: args ++ ["--force"], else: args
  end

  defp check_local_domain(domain, ip, hosts_file, fix?) do
    cond do
      String.trim(domain) == "" ->
        bad("local domain", "empty domain")

      String.ends_with?(domain, ".local") ->
        warn(
          "local domain",
          "#{domain} uses .local; prefer casein.test because .local is mDNS-owned"
        )

        check_hosts_mapping(domain, ip, hosts_file, fix?)

      true ->
        check_hosts_mapping(domain, ip, hosts_file, fix?)
    end
  end

  defp check_hosts_mapping(domain, ip, hosts_file, fix?) do
    case Casein.Setup.LocalDomain.resolve_ipv4(domain) do
      {:ok, ^ip} ->
        ok("local domain", "#{domain} resolves to #{ip}")

      {:ok, other_ip} ->
        warn("local domain", "#{domain} resolves to #{other_ip}, expected #{ip}")
        maybe_fix_hosts_file(domain, ip, hosts_file, fix?)

      {:error, _reason} ->
        warn("local domain", "#{domain} does not resolve")
        maybe_fix_hosts_file(domain, ip, hosts_file, fix?)
    end
  end

  defp maybe_fix_hosts_file(domain, ip, hosts_file, true) do
    case File.read(hosts_file) do
      {:ok, content} ->
        updated = Casein.Setup.LocalDomain.put_hosts_entry(content, domain, ip)
        write_hosts_file(hosts_file, updated, domain, ip)

      {:error, reason} ->
        warn("local domain", "could not read #{hosts_file}: #{:file.format_error(reason)}")
    end
  end

  defp maybe_fix_hosts_file(domain, ip, _hosts_file, false) do
    warn("local domain", "run doctor --fix to map #{domain} to #{ip}")
  end

  defp write_hosts_file(hosts_file, updated, domain, ip) do
    cond do
      hosts_file != @default_hosts_file ->
        File.write!(hosts_file, updated)
        ok("local domain", "updated #{hosts_file} with #{domain} -> #{ip}")

      writable?(hosts_file) ->
        File.write!(hosts_file, updated)
        ok("local domain", "updated #{hosts_file} with #{domain} -> #{ip}")

      true ->
        tmp = Path.join(System.tmp_dir!(), "casein-hosts-#{System.unique_integer([:positive])}")
        File.write!(tmp, updated)

        case System.cmd("sudo", ["-n", "install", "-m", "0644", tmp, hosts_file],
               stderr_to_stdout: true
             ) do
          {_out, 0} ->
            ok("local domain", "updated #{hosts_file} with #{domain} -> #{ip}")
            File.rm(tmp)

          {out, _status} ->
            warn(
              "local domain",
              "prepared #{tmp}; run: sudo install -m 0644 #{tmp} #{hosts_file}"
            )

            warn("sudo", String.trim(out))
        end
    end
  end

  defp cert_covers?(certfile, host) do
    case System.cmd("openssl", ["x509", "-in", certfile, "-noout", "-ext", "subjectAltName"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        String.contains?(out, "DNS:#{host}") or String.contains?(out, "IP Address:#{host}")

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp check_host_trust do
    with mkcert when is_binary(mkcert) <- System.find_executable("mkcert"),
         {caroot, 0} <- System.cmd(mkcert, ["-CAROOT"], stderr_to_stdout: true) do
      root_ca = Path.join(String.trim(caroot), "rootCA.pem")

      cond do
        not File.exists?(root_ca) ->
          warn("mkcert root CA", "missing; run mkcert -install once")

        p11_trusts_root_ca?() ->
          ok("host trust", "mkcert root CA is trusted by p11-kit")

        true ->
          warn("host trust", "run: sudo trust anchor #{root_ca}")
      end
    else
      _ -> warn("host trust", "mkcert CA root unavailable")
    end
  end

  defp check_nss_trust(fix?) do
    cond do
      is_nil(System.find_executable("certutil")) ->
        warn("Chromium/NSS trust", "certutil missing; Arch: sudo pacman -S nss")

      nss_has_mkcert?() ->
        ok("Chromium/NSS trust", "mkcert root CA is in ~/.pki/nssdb")

      fix? ->
        import_mkcert_into_nss()

      true ->
        warn("Chromium/NSS trust", "run doctor --fix to import mkcert into ~/.pki/nssdb")
    end
  end

  defp import_mkcert_into_nss do
    with mkcert when is_binary(mkcert) <- System.find_executable("mkcert"),
         certutil when is_binary(certutil) <- System.find_executable("certutil"),
         {caroot, 0} <- System.cmd(mkcert, ["-CAROOT"], stderr_to_stdout: true) do
      root_ca = Path.join(String.trim(caroot), "rootCA.pem")
      nssdb = Path.expand("~/.pki/nssdb")
      File.mkdir_p!(nssdb)

      _ =
        System.cmd(certutil, ["-N", "--empty-password", "-d", "sql:#{nssdb}"],
          stderr_to_stdout: true
        )

      _ =
        System.cmd(certutil, ["-D", "-d", "sql:#{nssdb}", "-n", "mkcert"], stderr_to_stdout: true)

      case System.cmd(
             certutil,
             ["-A", "-d", "sql:#{nssdb}", "-n", "mkcert", "-t", "C,,", "-i", root_ca],
             stderr_to_stdout: true
           ) do
        {_out, 0} -> ok("Chromium/NSS trust", "imported mkcert root CA into #{nssdb}")
        {out, _} -> warn("Chromium/NSS trust", String.trim(out))
      end
    else
      _ -> warn("Chromium/NSS trust", "mkcert root CA unavailable")
    end
  end

  defp check_firewall(port) do
    cond do
      System.find_executable("ufw") ->
        warn("firewall", "if another device times out, run: sudo ufw allow #{port}/tcp")

      System.find_executable("firewall-cmd") ->
        warn(
          "firewall",
          "if another device times out, run: sudo firewall-cmd --add-port=#{port}/tcp --permanent && sudo firewall-cmd --reload"
        )

      true ->
        warn("firewall", "make sure TCP #{port} is reachable from the LAN")
    end
  end

  defp check_lan_edge(edge?, edge_port, https_port, lan_host, fix?) do
    edge_open? = Casein.Setup.LanEdge.listener_open?(edge_port)
    backend_open? = Casein.Setup.LanEdge.listener_open?(https_port)

    cond do
      edge_open? and backend_open? ->
        ok(
          "portless LAN edge",
          "https://#{lan_host}/ is listening on :#{edge_port} and forwarding to :#{https_port}"
        )

      edge_open? ->
        warn(
          "portless LAN edge",
          "listening on :#{edge_port}, but Casein HTTPS backend is not listening on :#{https_port}; start with CASEIN_LAN=true mise exec -- mix phx.server or use http://#{lan_host}/"
        )

      edge? and fix? ->
        Mix.shell().info([
          "  ",
          "$ mix casein.edge.setup --fix --listen-port ",
          Integer.to_string(edge_port),
          " --backend-port ",
          Integer.to_string(https_port)
        ])

        Mix.Task.rerun("casein.edge.setup", [
          "--fix",
          "--listen-port",
          Integer.to_string(edge_port),
          "--backend-port",
          Integer.to_string(https_port)
        ])

      edge? ->
        warn(
          "portless LAN edge",
          "not listening; run doctor --fix --edge to prepare https://#{lan_host}/"
        )

      true ->
        warn(
          "portless LAN edge",
          "optional; run doctor --fix --edge to prepare https://#{lan_host}/"
        )
    end
  end

  defp check_insecure_http_edge(insecure_http?, insecure_http_port, backend_port, lan_host, fix?) do
    edge_open? = Casein.Setup.InsecureHttpEdge.listener_open?(insecure_http_port)
    backend_open? = Casein.Setup.InsecureHttpEdge.listener_open?(backend_port)

    cond do
      edge_open? and backend_open? ->
        ok(
          "insecure LAN HTTP",
          "http://#{lan_host}/ is listening on :#{insecure_http_port} and forwarding to :#{backend_port}"
        )

      edge_open? ->
        warn(
          "insecure LAN HTTP",
          "listening on :#{insecure_http_port}, but Casein HTTP backend is not listening on :#{backend_port}; run `mise exec -- mix casein.lan.up`"
        )

      insecure_http? and fix? ->
        Mix.shell().info([
          "  ",
          "$ mix casein.lan.up --listen-port ",
          Integer.to_string(insecure_http_port),
          " --backend-port ",
          Integer.to_string(backend_port),
          " --host ",
          lan_host
        ])

        Mix.Task.rerun("casein.lan.up", [
          "--listen-port",
          Integer.to_string(insecure_http_port),
          "--backend-port",
          Integer.to_string(backend_port),
          "--host",
          lan_host
        ])

      insecure_http? ->
        warn(
          "insecure LAN HTTP",
          "not listening; run `mise exec -- mix casein.lan.up` to prepare http://#{lan_host}/"
        )

      true ->
        warn(
          "insecure LAN HTTP",
          "optional trusted-LAN shortcut; run `mise exec -- mix casein.lan.up` for http://#{lan_host}/"
        )
    end
  end

  defp check_node_assets do
    cond do
      File.dir?("assets/node_modules") and File.dir?("priv/scripts/node_modules") ->
        ok("Node assets", "installed")

      File.exists?("assets/package.json") or File.exists?("priv/scripts/package.json") ->
        warn("Node assets", "run: npm ci --prefix assets && npm ci --prefix priv/scripts")

      true ->
        ok("Node assets", "not required")
    end
  end

  if Casein.Repo.Adapter.sqlite?() do
    defp check_database(fix?), do: check_sqlite(fix?)

    defp check_sqlite(fix?) do
      database_path =
        System.get_env("DATABASE_PATH") ||
          Path.expand("../casein_dev.sqlite3", System.tmp_dir!())

      database_dir = Path.dirname(database_path)

      cond do
        File.exists?(database_path) ->
          ok("SQLite", database_path)

        File.dir?(database_dir) and writable?(database_path) ->
          ok("SQLite", "#{database_path} will be created on migrate")

        fix? ->
          File.mkdir_p!(database_dir)
          ok("SQLite", "created #{database_dir}; #{database_path} will be created on migrate")

        true ->
          warn(
            "SQLite",
            "#{database_dir} is missing or not writable; create it or set DATABASE_PATH"
          )
      end
    end
  else
    defp check_database(_fix?), do: check_postgres()

    defp check_postgres do
      case System.cmd("bash", ["-lc", "timeout 2 bash -c '</dev/tcp/127.0.0.1/5432'"],
             stderr_to_stdout: true
           ) do
        {_out, 0} ->
          ok("Postgres", "127.0.0.1:5432 is reachable")

        _ ->
          warn("Postgres", "localhost:5432 is not reachable; start Postgres or set DATABASE_URL")
      end
    rescue
      _ -> warn("Postgres", "could not test localhost:5432")
    end
  end

  defp join_hosts(hosts) do
    hosts
    |> Enum.flat_map(fn
      value when is_binary(value) -> String.split(value, ",", trim: true)
      _ -> []
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.join(",")
  end

  defp p11_trusts_root_ca? do
    case System.cmd("trust", ["list", "--filter=ca-anchors"], stderr_to_stdout: true) do
      {out, 0} -> String.contains?(out, "mkcert")
      _ -> false
    end
  rescue
    _ -> false
  end

  defp nss_has_mkcert? do
    nssdb = Path.expand("~/.pki/nssdb")

    case System.cmd("certutil", ["-L", "-d", "sql:#{nssdb}"], stderr_to_stdout: true) do
      {out, 0} -> String.contains?(out, "mkcert")
      _ -> false
    end
  rescue
    _ -> false
  end

  defp unsafe_workspace_name?(name) do
    name in ["", ".", ".."] or String.contains?(name, "/")
  end

  defp edge_message(true, lan_host) do
    "With the LAN edge installed, open:\n\n      https://#{lan_host}/"
  end

  defp edge_message(false, lan_host) do
    "For portless access, run `mise exec -- mix casein.doctor --fix --edge`, then open `https://#{lan_host}/`."
  end

  defp insecure_http_message(false, lan_host) do
    "Managed LAN HTTP shortcut: run `mise exec -- mix casein.lan.up`, then open `http://#{lan_host}/`."
  end

  defp quick_start_message(%{insecure_http?: true} = assigns) do
    """

    Managed LAN HTTP quick start:

      mise exec -- mix casein.lan.up

    Then open:

      http://#{assigns.lan_host}/

    Check or stop it with:

      mise exec -- mix casein.lan.status
      mise exec -- mix casein.lan.down

    HTTPS LAN mode is still available with:

      CASEIN_LAN=true mise exec -- mix phx.server

    Same-host HTTPS fallback:

      https://#{assigns.local_domain}:#{assigns.https_port}/

    This defaults to workspace `#{assigns.workspace}` under:

      #{Path.expand(assigns.root)}

    To keep the workspace picker at `/`, start with:

      CASEIN_LAN_INSECURE_HTTP=true CASEIN_LAN_DIRECT_MODE=false mise exec -- mix phx.server
    """
  end

  defp quick_start_message(assigns) do
    """

    LAN quick start:

      CASEIN_LAN=true mise exec -- mix phx.server

    Then open:

      https://#{assigns.lan_host}:#{assigns.https_port}/

    #{edge_message(assigns.edge?, assigns.lan_host)}

    #{insecure_http_message(false, assigns.lan_host)}

    Same-host fallback:

      https://#{assigns.local_domain}:#{assigns.https_port}/

    This defaults to workspace `#{assigns.workspace}` under:

      #{Path.expand(assigns.root)}

    To keep the workspace picker at `/`, start with:

      CASEIN_LAN=true CASEIN_LAN_DIRECT_MODE=false mise exec -- mix phx.server
    """
  end

  defp port_for_firewall(true, _edge?, insecure_http_port, _edge_port, _https_port),
    do: insecure_http_port

  defp port_for_firewall(false, true, _insecure_http_port, edge_port, _https_port), do: edge_port

  defp port_for_firewall(false, false, _insecure_http_port, _edge_port, https_port),
    do: https_port

  defp truthy_env?(name) do
    System.get_env(name) in ~w(1 true TRUE yes YES on ON)
  end

  defp env_int(name) do
    case System.get_env(name) do
      nil -> nil
      value -> String.to_integer(value)
    end
  rescue
    ArgumentError -> nil
  end

  defp writable?(path) do
    path
    |> Path.dirname()
    |> File.stat()
    |> case do
      {:ok, %{access: access}} -> access in [:write, :read_write]
      _ -> false
    end
  end

  defp ok(label, detail), do: Mix.shell().info(["  OK    ", label, " - ", detail])
  defp warn(label, detail), do: Mix.shell().info(["  WARN  ", label, " - ", detail])
  defp bad(label, detail), do: Mix.shell().error(["  FAIL  ", label, " - ", detail])
end
