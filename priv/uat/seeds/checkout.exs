# Deterministic seed for the `checkout` UAT scenario.
#
# Runs inside the ephemeral workspace before the criterion executes. MUST be
# deterministic: fixed primary keys, frozen clock, no network calls, pinned
# locale/timezone. This is a placeholder — fill in real seeding for the
# app-under-test (e.g. insert a user with a saved card and a cart).
IO.puts("[uat seed] checkout: no-op placeholder — implement deterministic seeding")
