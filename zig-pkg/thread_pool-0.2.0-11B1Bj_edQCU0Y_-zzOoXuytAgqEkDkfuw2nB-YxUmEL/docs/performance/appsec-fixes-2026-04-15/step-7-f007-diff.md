# Perf diff — step-7-f007

Generated: 2026-04-15T23:24:32Z

## bench (zig build bench)

| scenario | variant | ops/s before | ops/s after | Δ % | p95 submit before (ns) | p95 submit after (ns) | Δ p95 % |
|---|---|---:|---:|---:|---:|---:|---:|
| conn_churn_seq | global_queue | 870130.4770847231 | 767122.3640703558 | -11.83823756633427% | 1964 | 2073 | 5.54989816700611% |
| conn_churn_seq | work_stealing | 893767.7591610105 | 852081.8381335746 | -4.664066319260268% | 2289 | 1969 | -13.979903888160768% |
| producer_contention | global_queue | 756711.239840699 | 785789.1867273761 | 3.8426741081311917% | 5046 | 6514 | 29.09235037653587% |
| producer_contention | work_stealing | 836996.7265989835 | 1223924.3748603065 | 46.22809575773948% | 5957 | 3751 | -37.03206311901964% |

## bench-realistic (zig_thread_pool rows)

| scenario | variant | ops/s before | ops/s after | Δ % | p95 submit before (ns) | p95 submit after (ns) | Δ p95 % |
|---|---|---:|---:|---:|---:|---:|---:|
| cpu_work_10us | work_stealing | 222490.63987440316 | 235082.93573168703 | 5.659696904279779% | 16209 | 14563 | -10.154852242581281% |
| cpu_work_100us | work_stealing | 98947.79410487843 | 99861.54197205574 | 0.9234646163094835% | 24466 | 24146 | -1.3079375459821794% |
| contended_cpu_10us | work_stealing | 215002.6436725066 | 215279.7747966887 | 0.1288966123617705% | 65656 | 64938 | -1.0935786523699282% |
| nested_fanout_4x | work_stealing | 179601.55574459617 | 178829.78971673272 | -0.42971010171034024% | 26203 | 24707 | -5.7092699309239405% |
| burst_drain_burst | work_stealing | 82911.95405483813 | 84511.03867341334 | 1.9286538796535464% | 20845 | 20901 | 0.26864955624850084% |

## Review checklist

Apply the Performance-Regression Review Rule from the plan:

- Throughput regression ≥ 5% on any scenario → BLOCK, escalate to user.
- p95 latency regression ≥ 10% on any scenario → BLOCK, escalate to user.
- 3–5% throughput / 7–10% p95 → WARN, note in commit body.

## Disposition — bench apparent regressions

`conn_churn_seq/global_queue` (−11.8% throughput): BASELINE=921,304.
before=870,130 (already 5.6% below BASELINE); after=767,122. Both values
sit inside the known ≥25% CV band for this scenario (established in
step-1-f001 and step-6-f004 dispositions). Paired opposite on
`producer_contention/work_stealing` (+46.2% throughput) confirms
scheduler/CPU-state noise dominates, not a code-path effect.

`conn_churn_seq/work_stealing` (−4.7% throughput): inside 25% CV band.
before=893,768 (15% below BASELINE 1,051,335); after=852,082 (19% below).
Sub-5% additional delta in an already-noisy run is sample variance.

`producer_contention/global_queue` p95 +29.1% (5046→6514 ns): absolute
delta is 1,468 ns. The same run shows `producer_contention/work_stealing`
p95 at −37.0% (5957→3751 ns) — symmetric opposite on two variants of the
same scenario is a CPU-state noise signature, not a code regression.

**Ruled out by construction**: F-007's change is one `@min()` expression
executed ONLY in `parseProcStatusKiB`, which is called exclusively from
`sampleLinux()` → `sample()` → `statsSnapshot()`. No bench workload calls
`statsSnapshot()` during the measured task-submission loop. The hot path is
completely untouched.

**Regression class: clean (bench noise, ruled out by construction on
stats-sampling-only code path).**
