defmodule DevIDE.UAT.Instance do
  @moduledoc """
  Boots and tears down an ephemeral DevIDE instance for a Tier A UAT run, against
  a temporary, seeded `DEV_IDE_WORKSPACES_ROOT` so the run has zero impact on the
  live release/session.

  The OS side effects go through a `DevIDE.UAT.Instance.Runner` (default
  `SystemRunner`, shelling out to `scripts/dev-preview-instance.sh`); this module
  owns the deterministic logic: allocate a port from `:preview_env_port_range`,
  stage the fixtures into a temp root, launch, poll for readiness, seed, and —
  always, success or failure — tear down by killing the launched PID and removing
  the temp root.
  """

  alias DevIDE.UAT.Instance.SystemRunner
  alias DevIDE.UAT.Manifest

  @enforce_keys [:scenario_id, :port, :handle, :workspaces_root, :base_url, :runner, :owns_root]
  defstruct [:scenario_id, :port, :handle, :workspaces_root, :base_url, :runner, :owns_root]

  @type t :: %__MODULE__{}

  @default_range {41_000, 41_099}

  @doc """
  Boot an instance for `manifest`.

  Options:

    * `:runner` — a `Runner` implementation (default `SystemRunner`)
    * `:port` — fixed port (default: first free port in `:preview_env_port_range`)
    * `:workspaces_root` — use this root instead of staging a temp one (caller-owned)
    * `:scenario_dir` — base dir for resolving `manifest.fixtures_dir`
    * `:probe_retries` (default 30), `:probe_delay_ms` (default 200)

  On any failure the temp root is removed and the partially-launched process is
  not leaked (the caller still calls `teardown/1` only on `{:ok, _}`; failures
  clean up internally).
  """
  @spec boot(Manifest.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def boot(%Manifest{} = manifest, opts \\ []) do
    with :ok <- Manifest.validate(manifest) do
      do_boot(manifest, opts)
    end
  end

  defp do_boot(manifest, opts) do
    runner = Keyword.get(opts, :runner, SystemRunner)
    {root, owns_root} = resolve_root(manifest, opts)

    with {:ok, port} <- allocate_port(opts),
         base_url = "http://127.0.0.1:#{port}",
         env = launch_env(root, port, manifest),
         {:ok, handle} <- runner.launch(%{port: port, workspaces_root: root, env: env}),
         :ok <- await_ready(runner, base_url, opts, handle),
         :ok <- maybe_seed(runner, manifest, root, handle) do
      {:ok,
       %__MODULE__{
         scenario_id: manifest.scenario_id,
         port: port,
         handle: handle,
         workspaces_root: root,
         base_url: base_url,
         runner: runner,
         owns_root: owns_root
       }}
    else
      {:error, reason} ->
        cleanup_root(root, owns_root)
        {:error, reason}
    end
  end

  @doc "Tear down: kill the launched PID (never a broad pattern) and remove the temp root."
  @spec teardown(t()) :: :ok
  def teardown(%__MODULE__{} = instance) do
    _ = instance.runner.kill(instance.handle)
    cleanup_root(instance.workspaces_root, instance.owns_root)
    :ok
  end

  # --- internals ------------------------------------------------------------

  defp resolve_root(manifest, opts) do
    case Keyword.get(opts, :workspaces_root) do
      nil -> {stage_temp_root(manifest, opts), true}
      root -> {root, false}
    end
  end

  # The temp root stays under System.tmp_dir! and uses a Manifest-validated scenario_id.
  # sobelow_skip ["Traversal.FileModule"]
  defp stage_temp_root(manifest, opts) do
    root =
      Path.join(System.tmp_dir!(), "uat-ws-#{manifest.scenario_id}-#{unique()}")

    File.mkdir_p!(root)
    copy_fixtures(manifest, opts, root)
    root
  end

  defp copy_fixtures(%Manifest{fixtures_dir: nil}, _opts, _root), do: :ok

  defp copy_fixtures(%Manifest{fixtures_dir: fixtures_dir}, opts, root) do
    case Keyword.get(opts, :scenario_dir) do
      nil -> :ok
      scenario_dir -> maybe_copy(fixture_source!(scenario_dir, fixtures_dir), root)
    end
  end

  # The source is resolved under the operator-provided scenario_dir and the destination is an owned temp root.
  # sobelow_skip ["Traversal.FileModule"]
  defp maybe_copy(from, to) do
    if File.dir?(from), do: File.cp_r!(from, to)
    :ok
  end

  defp fixture_source!(scenario_dir, fixtures_dir) do
    base = Path.expand(scenario_dir)
    source = Path.expand(fixtures_dir, base)

    if under_path?(source, base) do
      source
    else
      raise ArgumentError, "fixtures_dir escapes scenario_dir: #{inspect(fixtures_dir)}"
    end
  end

  defp launch_env(root, port, %Manifest{identity: identity}) do
    base = %{"DEV_IDE_WORKSPACES_ROOT" => root, "PORT" => Integer.to_string(port)}
    if identity, do: Map.put(base, "DEV_IDE_UAT_IDENTITY", identity), else: base
  end

  defp allocate_port(opts) do
    case Keyword.get(opts, :port) do
      nil -> find_free_port(configured_range())
      port when is_integer(port) -> {:ok, port}
    end
  end

  defp configured_range do
    Application.get_env(:dev_ide, :preview_env_port_range, @default_range)
  end

  defp find_free_port({lo, hi}) do
    Enum.reduce_while(lo..hi, {:error, :no_free_port}, fn port, acc ->
      case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true]) do
        {:ok, socket} ->
          :ok = :gen_tcp.close(socket)
          {:halt, {:ok, port}}

        {:error, _} ->
          {:cont, acc}
      end
    end)
  end

  defp await_ready(runner, base_url, opts, handle) do
    retries = Keyword.get(opts, :probe_retries, 30)
    delay = Keyword.get(opts, :probe_delay_ms, 200)
    probe_loop(runner, base_url, retries, delay, handle)
  end

  defp probe_loop(runner, base_url, retries, delay, handle) do
    case runner.probe(base_url) do
      :ok ->
        :ok

      {:error, reason} when retries <= 0 ->
        # Kill the half-started process so a failed boot doesn't leak it.
        _ = runner.kill(handle)
        {:error, {:not_ready, reason}}

      {:error, _reason} ->
        Process.sleep(delay)
        probe_loop(runner, base_url, retries - 1, delay, handle)
    end
  end

  defp maybe_seed(_runner, %Manifest{seed_cmd: nil}, _root, _handle), do: :ok

  defp maybe_seed(runner, %Manifest{seed_cmd: seed_cmd}, root, handle) do
    case runner.seed(seed_cmd, root) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = runner.kill(handle)
        {:error, {:seed_failed, reason}}
    end
  end

  defp cleanup_root(_root, false), do: :ok
  defp cleanup_root(nil, _owns), do: :ok

  # Only roots created by stage_temp_root/2 are removed; caller-owned roots pass owns_root=false.
  # sobelow_skip ["Traversal.FileModule"]
  defp cleanup_root(root, true) do
    root = Path.expand(root)
    if owned_temp_root?(root), do: _ = File.rm_rf(root)
    :ok
  end

  defp owned_temp_root?(root) do
    String.starts_with?(root, Path.join(System.tmp_dir!(), "uat-ws-"))
  end

  defp under_path?(path, base) do
    path == base or String.starts_with?(path, base <> "/")
  end

  defp unique, do: System.unique_integer([:positive])
end
