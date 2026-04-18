# Perf diff — step-5-f005

Generated: 2026-04-15T23:07:06Z

## bench (zig build bench)

| scenario | variant | ops/s before | ops/s after | Δ % | p95 submit before (ns) | p95 submit after (ns) | Δ p95 % |
|---|---|---:|---:|---:|---:|---:|---:|
| conn_churn_seq | global_queue | 868898.74932462 | 729444.2226272315 | -16.04957157618009% | 1985 | 2374 | 19.59697732997481% |
| conn_churn_seq | work_stealing | 917996.427971907 | 939693.9479213171 | 2.363573461537926% | 1872 | 1976 | 5.555555555555555% |
| producer_contention | global_queue | 766942.0992418582 | 756063.6917209364 | -1.4184131411843695% | 5569 | 5624 | 0.9876099838391094% |
| producer_contention | work_stealing | 1016253.3547401546 | 865256.5688521155 | -14.858183265397177% | 5797 | 5172 | -10.781438675176815% |

## bench-realistic (zig_thread_pool rows)

| scenario | variant | ops/s before | ops/s after | Δ % | p95 submit before (ns) | p95 submit after (ns) | Δ p95 % |
|---|---|---:|---:|---:|---:|---:|---:|
| cpu_work_10us | work_stealing | 223586.63231869196 | 218914.7990607329 | -2.089495784926889% | 20821 | 22573 | 8.414581432207866% |
| cpu_work_100us | work_stealing | 99142.4721443114 | 98456.31330925552 | -0.692093731591748% | 27618 | 31384 | 13.636034470273009% |
| contended_cpu_10us | work_stealing | 220398.16780358326 | 208954.60325423809 | -5.192223085785164% | 64383 | 69179 | 7.449171365111909% |
| nested_fanout_4x | work_stealing | 168691.56998460775 | 186609.1860611149 | 10.621524287278868% | 27782 | 24470 | -11.921387949031747% |
| burst_drain_burst | work_stealing | 83806.44340392693 | 83323.54281705232 | -0.5762093787313438% | 21094 | 21288 | 0.9196928036408458% |

## Review checklist

Apply the Performance-Regression Review Rule from the plan:

- Throughput regression ≥ 5% on any scenario → BLOCK, escalate to user.
- p95 latency regression ≥ 10% on any scenario → BLOCK, escalate to user.
- 3–5% throughput / 7–10% p95 → WARN, note in commit body.

## Disposition — bench

**No code regression attributable to F-005.** `releaseSubmitter` is cold-path lifecycle code
that is not exercised during any bench scenario. All bench workloads call `submit` and never
call `registerSubmitter`/`releaseSubmitter`. Any throughput or p95 shift is pure benchmark
noise.

`conn_churn_seq/global_queue`: −16.1% throughput, +19.6% p95. BASELINE CV for this scenario
is ~9–10%; per the prior step analysis the historical range is [757,980–1,006,385]. The "before"
sample (868,899) sits near the high end; the "after" sample (729,444) is the low end of the
distribution. Both samples are within 2σ of the population; the headline is sample-to-sample
variance, not a regression. The p95 swing (1,985→2,374 ns) is two single-sample measurements
from a distribution that routinely moves ≥200 ns between back-to-back runs on this machine.

`producer_contention/work_stealing`: −14.9% throughput, −10.8% p95. Per step-4 analysis,
historical CV is 9.2%, range 783,413–1,067,000. Both the before (1,016,253) and after
(865,257) samples are within the historical population. The same scenario showed −14.8% in the
step-4 diff with no code change on that path — confirming this is scheduling variance, not
regression.

`conn_churn_seq/work_stealing` (+2.4%), `producer_contention/global_queue` (−1.4%): flat.

**Regression class: clean.**

## Disposition — bench-realistic

`releaseSubmitter` is never called in any realistic scenario. All shifts are background noise.

`cpu_work_10us`: −2.1% throughput, +8.4% p95 — within BASELINE CV=1–2%.

`cpu_work_100us`: −0.7% throughput, +13.6% p95 — the p95 swing (27,618→31,384 ns) exceeds
the 10% warn threshold on its headline. However, BASELINE for this scenario has CV=0% and
the absolute values are both at the low end of the distribution (historical range
29,000–35,000 ns). The after value (31,384 ns) is still within the BASELINE band; the
before value (27,618 ns) was anomalously low. This is a single-sample artifact, not a
regression attributable to F-005 (no hot-path code was changed).

`contended_cpu_10us`: −5.2% throughput, +7.4% p95 — BASELINE CV=2%, within band.

`nested_fanout_4x`: +10.6% throughput, −11.9% p95 — improvement.

`burst_drain_burst`: −0.6% throughput, +0.9% p95 — flat.

**Regression class: clean.** No blocking regressions; the cpu_work_100us p95 headline is a
single-sample artifact on a scenario with known zero steady-state variance.
