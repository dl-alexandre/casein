import Config

# Register the Repo so Mix tasks (mix ecto.create, mix ecto.migrate) can
# discover it. The actual database path is configured at runtime in
# DevideMob.Repo.init/2 via the MOB_DATA_DIR environment variable.
config :devide_mob, ecto_repos: [DevideMob.Repo]

# Wire the Repo into Mob.ScreenState so screens using `vsn:` get automatic
# state persistence. Remove this line to disable screen state persistence.
config :mob, :repo, DevideMob.Repo
