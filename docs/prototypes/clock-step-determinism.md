# Prototype: `Casein.Clock` step-determinism (#897)

Status: **verdict recorded** — feasibility probe, not a DST runtime.

Parent: [#897](https://github.com/dl-alexandre/casein/issues/897).
Held behind this: [#898](https://github.com/dl-alexandre/casein/issues/898) (DST/VOPR).

Subsystem under test: **drain only** (`Casein.Deployment.Drain`). Size-convergence
was left untouched.

## Verdict

**Step-determinism holds on the BEAM under a closed scheduler. It does not
hold as a drop-in `Process.send_after/3` replacement on a live GenServer.**

| Question | Answer |
|----------|--------|
| Same seed + scripted events + virtual timers → same trace? | **Yes** (20/20 identical drain replays; seed 42 == seed 42, ≠ seed 43). |
| Virtual `send_after` alone enough for DST on Drain as it runs today? | **No.** |
| What #898 must own before generators/faults | Every async source, not just timers. |

One-line for the board: `determinism=holds` constraints=`serial scheduler owns timers and external events; same-ms ordered by schedule seq; GenServer.call barrier after each inject` breaks=`real Process.monitor :DOWN vs timer at one logical instant; :sys.get_state as a barrier; PubSub side effects; concurrent send_after into the clock`.

## What was built

- `Casein.Clock` / `Casein.Clock.Scheduler` — virtual time + timer heap.
- Drain timers (`grace` / `auto_reconnect` / `hard`) go through
  `Casein.Clock.send_after/3`. No scheduler running ⇒ real
  `Process.send_after/3` (production unchanged).
- Probe tests in `test/casein/clock_test.exs` and
  `test/casein/deployment/drain_clock_prototype_test.exs`.

No fault injection, no invariant checkers, no generators. Those stay on #898.

## What holds

A single process owns the timer heap. `step/0` / `advance_to/1` deliver the
next due message in `{due_ms, seq}` order (`seq` is the schedule order). The
test then waits with `Clock.sync/1` (`GenServer.call(dest, :clock_sync)`),
which is a regular mailbox message and so lands *after* the timer just sent.

Under that discipline, Drain's observable state
`{t, count, draining, grace?, auto?, hard?, stopped_at}` is a function of the
script. The same script, or the same seed expanded into disconnect times, is
byte-identical across repeats.

## What breaks it

1. **Real monitors.** Drain tracks LiveViews with `Process.monitor/1`. A
   `:DOWN` and a virtual `:auto_reconnect` at the same logical instant are
   two senders into one mailbox. Order is not defined.
   - `:auto_reconnect` first (count > 0) ⇒ `{:deploy_reconnect}` broadcast,
     then `:DOWN` arms grace.
   - `:DOWN` first (count == 0) ⇒ grace arms, `:auto_reconnect` is a no-op.
   The probe forces both orders. Traces differ. This is the drain/reload
   coupling that made the original flakes hard to copy: the bug is a
   mailbox race, not a slow clock.
2. **`:sys.get_state/1` as a step barrier.** `gen` selective-receives
   `{system, _, _}` ahead of pending infos. After `Clock.step/0` the timer
   message can still be in the mailbox while `get_state` returns a
   pre-timer snapshot. `Clock.sync/1` exists because of this. Using
   `:sys.get_state/1` to "wait for the step" is itself a determinism bug.
3. **Anything else that is not in the heap.** `Phoenix.PubSub.broadcast/3`
   is another process. `make_ref/0` / pids in a trace will never replay.
   Two processes calling `Clock.send_after/3` concurrently race `seq`.
4. **Open-world stepping.** Replacing `send_after` and letting the real
   runtime run does not produce a seed-reproducible sequence. The BEAM
   scheduler, not the clock, still orders `:DOWN`, casts, and PubSub.

## Implication for #898

Do not start VOPR/faults on the back of "we have a Clock." A DST harness
has to enqueue **monitors, casts, and other-process sends** on the same
timeline as timers (or refuse to count them as part of the sequence).
Virtual time is necessary and, by itself, not sufficient.

If #898 cannot budget a closed scheduler, redesign rather than wrap more
`send_after` calls. A negative result here would have been "the BEAM cannot
do this at all." That is not the result. The result is: **it can, but only
inside a scheduler that already looks like the #898 design, not like a
clock module.**
