# perf sched report — ce0d56b (source equiv) flood_1m

Baseline context: flood_1m median 566K ops/s n=10 (Task 1, commit 3506b29).
Wall-clock of traced run: 2728.371 ms (elapsed_ns=2728371311 from perf-sched-stdout.txt).
Perf instrumentation tax: traced 366,519 ops/s vs 566K untraced (~35.2% overhead).

## Submitter thread

- Name/tid: thread-pool-tok / 1165350
- Runtime: 2739.022 ms
- Switches: 17
- Avg wait: 0.017 ms
- Max wait: 0.036 ms
- **% running:** 100.4% (2739.022 / 2728.371; effectively pegged — submitter ran continuously and was only descheduled by kernel preemption during flood_1m)
- **% blocked:** 0% during flood_1m (post-flood teardown / contended_spawn_8x phase later contributes the only voluntary sleeps)
- **Dominant block cause:** R (runnable, kernel-preempted) — 6/6 deschedule events during flood_1m have prev_state=R; zero S/D events during flood_1m. Across the whole 2.94 s trace the submitter shows 6 R, 6 S, 4 D, 1 Z, but every S/D entry occurs **after** the flood_1m elapsed timestamp (338383.843 s). Interpretation: submitter is fully CPU-bound during flood_1m — never voluntarily blocks on a futex/condvar; the only off-CPU time is involuntary preemption by the scheduler. No park-mutex / queue-full backpressure observed on the submit path.

## Worker threads (nproc=56)

- Worker count in trace: 56 (TIDs 1165351–1165407 range, identified by switch-count signature ~17,800 — matches 1M tasks / 56 workers ≈ 17,857 dequeues/worker)
- Median worker Runtime: 219.761 ms
- Median worker % running: 8.05% (219.761 / 2728.371)
- Workers > 50% blocked: 56 / 56 (all workers; max worker % running is only 10.19% = 277.965 / 2728.371)
- Hot worker (if any): TID 1165353 at 277.965 ms (10.19%); spread is tight 204.545–277.965 ms (1.36×) — no anomalous hot worker

## Critical-path determination

**Finding:** Submitter is the critical path — it runs at 100% CPU for the full 2.728 s (zero voluntary blocks) while 56 workers sit idle ~92% of the time waiting for work; the bottleneck is submitter throughput, not worker capacity or contention.

## Deltas vs pre-G2 (2026-04-12)

Pre-G2: submitter 89% CPU-bound.
Current: submitter 100% running.

**Material shift?** yes — direction: even **more** CPU-bound (89% → ~100%, an ~11 pp shift toward pure-CPU). Implication for Task 3/4/5 A/B prioritization: G2's removal of the queued_tasks idle-spin closed the remaining 11 pp of submitter off-CPU time — the submit path is now fully compute-bound on `submitted.fetchAdd` + descriptor CAS + wake-scan. Promote **Task 3 (submitted.fetchAdd / G3 ceiling)** and **Task 4 (descriptor CAS)** to highest priority — they directly target submitter compute. Task 5 (wake-scan) is still compute on the submit path but its pre-G2 +47% is suspect now that there's no off-CPU time to cannibalize; expect smaller delta or possibly null. Worker-side or futex-side optimizations are dead weight here — workers are starved, not bottlenecked.

## Notes

- Submitter has only **17 context switches** across 2.94 s of trace — extremely low switch density confirms it never sleeps. Long uninterrupted runs of 48 / 260 / 612 / 683 / 309 / 821 ms (sum ≈ 2733 ms ≈ submitter runtime) cover the entire flood_1m window.
- All voluntary blocking (S states) happens **after** flood_1m completes — these reflect contended_spawn_8x submitter waits (8 submitters in that scenario do block on each other) and pool teardown, not flood_1m behavior.
- Worker switch count (~17,800 ≈ 1e6 / 56) shows workers are dequeue-and-sleep on every task — they wake to take exactly one task and immediately re-park, indicating the submitter cannot keep the per-worker local queues full. Confirms producer-bound shape.
- Two perf record warnings: "1 out of order events recorded" — non-fatal, accounting for it: 10.84M sched samples captured cleanly across ~2.94 s.
- nproc reports 56; std.Thread.getCpuCount in Zig (clamped to 64) also returned 56 for flood_1m → 56 worker threads created. The 64-thread cluster at TIDs 1165848–1165911 belongs to contended_spawn_8x (8 submitters + 56 workers).
- Latency table is unusually clean: avg delays of 0.006–0.076 ms across all 56 workers; sched-side wait noise is not the bottleneck. The bottleneck is purely submitter compute throughput.
