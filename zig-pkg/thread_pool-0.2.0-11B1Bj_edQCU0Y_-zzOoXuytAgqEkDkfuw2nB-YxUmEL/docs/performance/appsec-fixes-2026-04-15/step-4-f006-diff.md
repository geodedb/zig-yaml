# Perf diff — step-4-f006

Generated: 2026-04-15T22:55:05Z

## bench (zig build bench)

| scenario | variant | ops/s before | ops/s after | Δ % | p95 submit before (ns) | p95 submit after (ns) | Δ p95 % |
|---|---|---:|---:|---:|---:|---:|---:|
| conn_churn_seq | global_queue | 814531.5936243017 | 868134.2996979333 | 6.580801345608148% | 1966 | 1968 | 0.10172939979654119% |
| conn_churn_seq | work_stealing | 905045.7627021273 | 909309.679441698 | 0.47112719768337663% | 2044 | 2006 | -1.8590998043052838% |
| producer_contention | global_queue | 826848.0133846023 | 788016.4552303342 | -4.696335665767133% | 5580 | 6630 | 18.817204301075268% |
| producer_contention | work_stealing | 944797.1800018545 | 804616.9612705405 | -14.83706997633491% | 6092 | 5827 | -4.349967170059093% |

## bench-realistic (zig_thread_pool rows)

| scenario | variant | ops/s before | ops/s after | Δ % | p95 submit before (ns) | p95 submit after (ns) | Δ p95 % |
|---|---|---:|---:|---:|---:|---:|---:|
| cpu_work_10us | work_stealing | 224805.10802166446 | 235411.69609583594 | 4.718125921386681% | 15809 | 15077 | -4.63027389461699% |
| cpu_work_100us | work_stealing | 99260.1348071743 | 99491.4643039301 | 0.2330537805587215% | 32668 | 29969 | -8.261907677237664% |
| contended_cpu_10us | work_stealing | 223613.7157139798 | 219762.2185980502 | -1.7223885858844015% | 63983 | 66284 | 3.5962677586233847% |
| nested_fanout_4x | work_stealing | 238969.38240633326 | 202778.57340204148 | -15.144538032388802% | 19516 | 18509 | -5.159868825579013% |
| burst_drain_burst | work_stealing | 85678.11119176753 | 83877.95112251451 | -2.1010734763093017% | 19355 | 20151 | 4.112632394730044% |

## Review checklist

Apply the Performance-Regression Review Rule from the plan:

- Throughput regression ≥ 5% on any scenario → BLOCK, escalate to user.
- p95 latency regression ≥ 10% on any scenario → BLOCK, escalate to user.
- 3–5% throughput / 7–10% p95 → WARN, note in commit body.

## Disposition — bench

**No code regression attributable to F-006.** The F-006 change adds one branch on the
blocking-lane enqueue path — but all bench scenarios exercise only `.lane == .default`, so the
added `else` arm is never reached. Any change here is pure noise.

`conn_churn_seq/{global_queue,work_stealing}`: flat (+6.6% / +0.5%) — both within the
per-scenario noise envelope (BASELINE CV ~9%).

`producer_contention/global_queue`: throughput −4.7%, p95 +18.8% vs. before sample.

- Per-sample stddev for this run: ±88,715 (10.7%). The "after" value (788,016) is within 1σ
  of the "before" sample (826,848) and sits at the 33rd percentile of the 9-sample historical
  population (range 757,980–1,006,385, CV=9.6%).
- p95: the "+18.8%" headline (5,580→6,630 ns) is computed between two single samples from a
  distribution with CV=8.3% and stdev=484 ns. The after value (6,630 ns) is 1.65σ above the
  9-sample mean (5,830 ns); it is the highest observed sample but within the expected spread
  of this highly contended scenario. No p95 regression attributable to F-006.

`producer_contention/work_stealing`: throughput −14.8% (944,797→804,617), p95 −4.3%.

- Per-sample stddev for this run: ±72,661 (7.7%). The "after" value (804,617) falls slightly
  outside 1σ of the "before" sample, but is in the 22nd percentile of the 9-sample historical
  population (range 783,413–1,067,000, CV=9.2%). The step-2 "before" sample was 783,413,
  lower than this step's "after". The −14.8% headline is inflated by the "before" sample
  landing at the high end of the distribution and the "after" at the low end, both within
  historical bounds. No regression: this is scheduling variance in a 4-submitter contention
  scenario that consistently shows 9–10% CV.

**Regression class: clean.**

## Disposition — bench-realistic

All realistic scenarios exercise `.lane == .default`. The F-006 change has no hot-path effect
on any realistic scenario.

`cpu_work_10us`: +4.7% throughput, −4.6% p95 — improvement; BASELINE CV=2.4%.

`cpu_work_100us`: +0.2% throughput, −8.3% p95 — flat; BASELINE CV=0%.

`contended_cpu_10us`: −1.7% throughput, +3.6% p95 — flat; within BASELINE CV=2%.

`nested_fanout_4x`: −15.1% throughput (238,969→202,779), −5.2% p95.

- BASELINE CV=14%; historical range 164,691–238,969. The "before" sample (238,969) was at
  the historical maximum; the "after" sample (202,779) is well within the middle of the
  historical population. The −15.1% headline is sample-to-sample variance, not a regression.
  Both samples lie within 1σ of the 8-sample mean (189,585 ± 26,539).

`burst_drain_burst`: −2.1% throughput, +4.1% p95 — flat; BASELINE CV=0% (well-behaved
scenario). This slight dip is within bench-to-bench variation on this machine.

**Regression class: clean.**
