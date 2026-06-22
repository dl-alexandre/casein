# Development — connecting to a running Mob app

> Goal: clone → `mix mob.dev.setup` → `bin/dev-mobile` → a live, introspectable,
> hot-reloadable IEx session into the app on simulator or device.

## One-time setup

```bash
mix deps.get
mix mob.dev.setup          # generates per-developer secrets + installs bin/dev-mobile
```

`mob.dev.setup` writes a gitignored `.env.dev` containing a **random cookie
unique to you** (base32, chmod 600) and a loopback node name. It never creates a
shared or default cookie.

Wire `config/runtime.exs` to read those (dev only):

```elixir
if config_env() == :dev do
  config :my_app, :mob_dev,
    node:   System.fetch_env!("MOB_NODE"),
    cookie: System.fetch_env!("MOB_COOKIE")
end
```

## Daily use

```bash
bin/dev-mobile            # MOB_DEFAULT_DEVICE or "emulator"
bin/dev-mobile iphone     # explicit device
```

The script sources `.env.dev`, starts the hot-reload watcher in its own process
group (so exiting tears down the whole tree, not just the `mix` wrapper),
**polls** for the device to come up (no blind `sleep`), then drops you into IEx.

## Physical Device Networking (read before connecting a real phone)

A distributed Erlang node with your cookie is **remote code execution** for
anyone who can reach EPMD (`4369`) and the node port. So the device must **not**
expose those on Wi-Fi. The supported model is a **USB tunnel** — the BEAM binds
to `127.0.0.1` on the device, and your machine reaches it over the cable:

**Android**
```bash
adb forward tcp:4369 tcp:4369        # EPMD
adb forward tcp:<node_port> tcp:<node_port>
```

**iOS** (libimobiledevice)
```bash
iproxy 4369 4369                     # EPMD
iproxy <node_port> <node_port>
```

`app@mobile.local` over Wi-Fi via mDNS is intentionally **not** the default. It
is convenient and it is an open RCE surface; don't ship it as the happy path.

**Simulator** shares the host loopback, so no tunnel is needed — this is the easy
path and a good first target.

## Backgrounding — what actually happens

This is a **platform limit, not a DX gap a script can fix**:

- **iOS** suspends the app in the background. Your distribution/IEx link **will
  drop.** `Mob.Dev.Connection` is built around **reconnect-on-foreground**; it
  does not pretend the link survives. Background fetch / silent push cannot keep
  a persistent IEx session alive.
- **Android** can hold a foreground service to keep the BEAM alive longer, but
  still treat backgrounded as degraded and lean on MeshX store-and-forward.

## Files installed

| File | Purpose |
|------|---------|
| `.env.dev` | per-developer random cookie + loopback node (gitignored, 600) |
| `bin/dev-mobile` | one-command dev loop (watcher + poll + IEx) |
| `lib/mob/dev.ex` | dev-only distribution bootstrap; **no default cookie** |
| `lib/mob/dev/connection.ex` | supervised lifecycle owner (reconnect-on-foreground) |
| `lib/mix/tasks/mob.dev.setup.ex` | idempotent setup task |
