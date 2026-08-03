defmodule CaseinMob.PluginSupplyChainTest do
  use ExUnit.Case, async: false

  alias MobDev.Plugin
  alias MobDev.Plugin.{RuntimeManifest, SignatureGate, Verify}
  alias MobDev.NativeBuild

  @committed_manifest Path.expand("../../priv/generated/mob_plugins.exs", __DIR__)
  @legacy_hex_plugins [:mob_camera, :mob_scanner, :mob_location, :mob_biometric]
  @configured_plugins @legacy_hex_plugins ++ [:mob_notify]

  test "all configured plugin manifests resolve from exact dependency sources" do
    configured = Plugin.activated_names()
    dependency_paths = Mix.Project.deps_paths()
    lock = Mix.Dep.Lock.read()
    mob_config = Config.Reader.read!(Path.expand("../../mob.exs", __DIR__))[:mob] || []

    assert configured == @configured_plugins
    assert Keyword.get(mob_config, :acknowledge_unsafe_plugins, []) == []

    assert Enum.all?(configured, fn name ->
             case Map.fetch(dependency_paths, name) do
               {:ok, path} -> is_binary(path) and File.dir?(path)
               :error -> false
             end
           end)

    activated = Plugin.activated()

    assert Enum.map(activated, fn {_path, %{name: name}} -> name end) == configured

    assert Enum.all?(@legacy_hex_plugins, fn name ->
             lock
             |> Map.fetch!(name)
             |> checksum_pinned_hex?()
           end)

    assert {:git, _url, revision, options} = Map.fetch!(lock, :mob_notify)
    assert Keyword.fetch!(options, :ref) == revision
  end

  test "checksum-pinned Hex plugins remain authenticated v1" do
    activated = activated_by_name()

    Enum.each(@legacy_hex_plugins, fn name ->
      {path, manifest} = Map.fetch!(activated, name)
      assert {:ok, 1} = Verify.verify_plugin_with_version(path, manifest)
    end)
  end

  @tag :requires_mob_notify_v2
  test "mob_notify is authenticated v2 and the activation gate passes" do
    activated = Plugin.activated()
    {path, manifest} = Map.fetch!(Map.new(activated, &plugin_entry/1), :mob_notify)

    assert {:ok, 2} = Verify.verify_plugin_with_version(path, manifest)
    assert :ok = SignatureGate.check_activated(activated)
  end

  test "committed plugin manifest is a stable fresh render" do
    activated = Plugin.activated()

    fresh_bytes =
      activated
      |> RuntimeManifest.build()
      |> RuntimeManifest.render()

    assert fresh_bytes ==
             activated
             |> RuntimeManifest.build()
             |> RuntimeManifest.render()

    assert File.read!(@committed_manifest) == fresh_bytes
  end

  test "deprecated direct Android install fails before touching a device" do
    parent = self()
    apk = "/synthetic/casein.apk"
    serial = "synthetic-target"

    runner = fn command, args ->
      send(parent, {:synthetic_install_attempt, command, args})
      {"Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]", 1}
    end

    # Keep the retired boundary covered without compiling a deprecated direct call.
    assert {:error, :authoritative_transaction_required} =
             apply(NativeBuild, :install_android_updates, [apk, [serial], runner])

    refute_received {:synthetic_install_attempt, _, _}

    assert {:failed, :signature_mismatch} =
             NativeBuild.interpret_adb_update(
               "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]",
               1
             )
  end

  defp activated_by_name do
    Plugin.activated()
    |> Map.new(&plugin_entry/1)
  end

  defp plugin_entry({path, %{name: name} = manifest}), do: {name, {path, manifest}}

  defp checksum_pinned_hex?(
         {:hex, _package, version, package_checksum, _managers, _dependencies, "hexpm",
          outer_checksum}
       ) do
    is_binary(version) and version != "" and is_binary(package_checksum) and
      byte_size(package_checksum) == 64 and is_binary(outer_checksum) and
      byte_size(outer_checksum) == 64
  end

  defp checksum_pinned_hex?(_lock_entry), do: false
end
