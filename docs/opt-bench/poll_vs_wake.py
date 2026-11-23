"""Model of the app's race-wait loops: an outcome lands at a random time
inside the wait; the waiter either polls on a fixed interval (main) or is
woken by the publisher (claude/opt-1). Measures detection delay (outcome
landed -> waiter notices) and waiter wake-ups. Host-side asyncio model,
NOT a device measurement."""
import asyncio, random, statistics, sys, time

async def trial(mode, interval, land_after):
    done = asyncio.Event(); outcome_at = None; wakeups = 0
    async def publisher():
        nonlocal outcome_at
        await asyncio.sleep(land_after); outcome_at = time.perf_counter(); done.set()
    p = asyncio.create_task(publisher())
    while True:
        if outcome_at is not None: break
        wakeups += 1
        if mode == "poll":
            await asyncio.sleep(interval)
        else:  # nap: return on signal or after interval (same upper bound)
            try: await asyncio.wait_for(done.wait(), interval)
            except asyncio.TimeoutError: pass
    seen = time.perf_counter(); await p
    return (seen - outcome_at) * 1000, wakeups

async def main():
    random.seed(7)
    sites = [("SourceHealth.run", .025, (0.3, 3.0)), ("KK host race", .05, (0.3, 3.0)),
             ("poster resolve", .05, (0.05, 2.0)), ("findAlternatives", .1, (0.5, 6.0)),
             ("probeKK", .05, (0.3, 3.0))]
    for name, iv, (lo, hi) in sites:
        for mode in ("poll", "wake"):
            res = await asyncio.gather(*[trial(mode, iv, random.uniform(lo, hi)) for _ in range(300)])
            d = [r[0] for r in res]; w = [r[1] for r in res]
            print(f"{name:18s} {mode:4s} interval={int(iv*1000)}ms  delay mean={statistics.mean(d):6.1f}ms "
                  f"p95={sorted(d)[int(.95*len(d))]:6.1f}ms  wakeups/wait mean={statistics.mean(w):5.1f}")
asyncio.run(main())
