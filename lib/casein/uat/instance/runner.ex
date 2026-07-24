defmodule Casein.UAT.Instance.Runner do
  @moduledoc """
  The seam between `Casein.UAT.Instance` and the operating system.

  `Instance` owns the *logic* — port allocation, the readiness loop, temp-root
  setup/teardown, seed ordering — and delegates every side effect (spawning a
  server, probing it, killing it) to a Runner. The default
  `Casein.UAT.Instance.SystemRunner` shells out; tests inject a fake so the
  lifecycle is verifiable without booting a real Phoenix instance.

  `launch/1` returns an opaque `handle` that is threaded back into `kill/1`, so a
  runner that needs to retain a `Port` (or other state) to tear down by PID can.
  """

  @type launch_spec :: %{port: pos_integer(), workspaces_root: String.t(), env: map()}
  @type handle :: term()

  @callback launch(launch_spec()) :: {:ok, handle()} | {:error, term()}
  @callback probe(base_url :: String.t()) :: :ok | {:error, term()}
  @callback seed(seed_cmd :: String.t(), workspaces_root :: String.t()) :: :ok | {:error, term()}
  @callback kill(handle()) :: :ok
end
