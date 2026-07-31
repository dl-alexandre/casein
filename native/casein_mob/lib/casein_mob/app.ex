defmodule CaseinMob.App do
  @moduledoc "Application entry point for CaseinMob."

  use Mob.App

  @impl Mob.App
  def navigation(_platform) do
    stack(:main, root: CaseinMob.SessionDashboardScreen)
  end

  @impl Mob.App
  def on_start do
    CaseinMob.ConnectionTiming.start_boot()
    # Configure BEAM's DNS path so Req / Finch / Mint / `gen_tcp:connect/3`
    # with a hostname work on iOS without per-host setup. Flips the lookup
    # chain from the iOS-broken `:native` (inet_gethost port program) path
    # to `[:file, :dns]` and seeds Google + Cloudflare as fallback
    # nameservers. Override with `nameservers:` if you need to (corporate
    # resolver, Quad9, etc.) — see `Mob.DNS.configure_pure_beam/1`.
    #
    # For hosts that need Apple's resolver (VPN-pushed DNS, mDNS,
    # captive portals, search-domain expansion) call `Mob.DNS.resolve/1`
    # for those specific hostnames here too. Both paths compose.
    Mob.DNS.configure_pure_beam()

    # The pure-BEAM resolver (forced 8.8.8.8/1.1.1.1) returns :nxdomain for the
    # devbox host on some networks even though it's public; resolve it via the
    # OS resolver instead, which seeds :inet_db so the session socket connects.
    # (See the Mob.DNS note above re: hosts that need Apple's resolver.)
    resolve_session_hosts()
    |> dns_timing_opts()
    |> then(&CaseinMob.ConnectionTiming.boot_stage(:dns_ready, &1))

    {:ok, _} = Application.ensure_all_started(:castore)
    # Mob invokes this callback directly on-device instead of starting the
    # Mix application tree, so Req's shared Finch registry is not otherwise
    # guaranteed to exist before a pairing-token exchange.
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _} = Application.ensure_all_started(:slipstream)
    CaseinMob.ConnectionTiming.boot_stage(:dependencies_ready)
    start_device_bridge()
    # SessionClient atomically takes the cold timing context here and becomes
    # its sole owner. App startup continues concurrently but must not append
    # later stages to the handed-off shared-feed chain.
    start_session_client()
    {:ok, _} = CaseinMob.Repo.start_link()

    Ecto.Migrator.with_repo(CaseinMob.Repo, fn repo ->
      Ecto.Migrator.run(repo, migrations_dir(), :up, all: true)
    end)

    Mob.Screen.start_root(CaseinMob.SessionDashboardScreen)
    Mob.Dist.ensure_started(node: :"casein_mob_android@127.0.0.1", cookie: :mob_secret)
  end

  @doc false
  def resolve_session_hosts(resolver \\ &Mob.DNS.resolve/1) when is_function(resolver, 1) do
    case CaseinMob.SessionConfig.pairing() do
      {:ok, url, _token} -> resolve_session_url(url, resolver)
      :error -> {:skip, :no_configuration}
    end
  rescue
    _ -> {:error, :resolution_failed}
  catch
    :exit, _reason -> {:error, :resolution_failed}
  end

  @doc false
  def dns_timing_opts({:ok, :resolved}),
    do: [outcome: :succeeded, reason_code: :dns_resolved]

  def dns_timing_opts({:skip, :ip_literal}),
    do: [outcome: :skipped, reason_code: :dns_ip_literal]

  def dns_timing_opts({:skip, :no_configuration}),
    do: [outcome: :skipped, reason_code: :no_configuration]

  def dns_timing_opts({:error, :invalid_url}),
    do: [outcome: :failed, reason_code: :dns_invalid_url]

  def dns_timing_opts(_failure),
    do: [outcome: :failed, reason_code: :dns_resolution_failed]

  defp resolve_session_url(url, resolver) do
    case URI.parse(url).host do
      host when is_binary(host) and host != "" -> resolve_session_host(host, resolver)
      _invalid -> {:error, :invalid_url}
    end
  end

  defp resolve_session_host(host, resolver) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _address} -> {:skip, :ip_literal}
      {:error, _reason} -> resolve_session_hostname(host, resolver)
    end
  end

  defp resolve_session_hostname(host, resolver) do
    case resolver.(host) do
      {:ok, _address} -> {:ok, :resolved}
      {:error, _reason} -> {:error, :resolution_failed}
      _unexpected -> {:error, :resolution_failed}
    end
  end

  # Returns the path to the migrations directory for the current environment.
  #
  # WHY NOT Application.app_dir/2?
  #
  # Application.app_dir(app, "priv/repo/migrations") calls :code.priv_dir(app)
  # under the hood. That works in a normal `mix run` dev environment where the
  # app lives in $OTP_ROOT/lib/APP-VERSION/ebin/.
  #
  # On Android and iOS, Mob deploys .beam files to a flat -pa directory with no
  # versioned lib structure, so :code.priv_dir/1 returns {error, bad_name}.
  # Ecto.Migrator.run/3 silently finds zero migrations and logs "Migrations
  # already up" — tables are never created and any query against them crashes
  # the screen GenServer, making the screen appear frozen.
  #
  # The fix: mob_beam.c/mob_beam.m set MOB_BEAMS_DIR=beams_dir before erl_start.
  # The deployer pushes priv/ into beams_dir/priv/ and runs chmod -R 755 on it
  # (mkdir-as-root creates system:system drwxrwx--x dirs that the app process
  # can traverse but not list, breaking Path.wildcard). Here we read MOB_BEAMS_DIR
  # and pass the explicit path to Ecto.Migrator.run/4.
  defp migrations_dir do
    case System.get_env("MOB_BEAMS_DIR") do
      nil -> Application.app_dir(:casein_mob, "priv/repo/migrations")
      beams_dir -> Path.join([beams_dir, "priv", "repo", "migrations"])
    end
  end

  defp start_device_bridge do
    case CaseinMob.DeviceBridge.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  # Session companion channel client. Starts disconnected; connects once a
  # host pairing is provisioned (QR scan or a `config :casein_mob, :session`
  # dev default). See CaseinMob.SessionClient.
  defp start_session_client do
    case CaseinMob.SessionClient.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
