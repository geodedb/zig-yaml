use std::env;
use std::fs::File;
use std::io::{self, Write};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Instant;

use serde::Serialize;
use tokio::runtime::{Builder, Runtime};
use tokio::sync::Notify;

const FLOOD_TASK_COUNT: usize = 1_000_000;
const CONTENDED_TASK_COUNT: usize = 100_000;
const CONTENDED_SUBMITTERS: usize = 8;

#[derive(Clone)]
struct Args {
    output_path: Option<String>,
    runtime_version: String,
    source_commit: Option<String>,
    samples: usize,
    warmup_discard: usize,
}

#[derive(Clone, Copy, Default)]
struct SampleResult {
    elapsed_ns: u64,
    latency_p50_us: u64,
    latency_p95_us: u64,
    latency_p99_us: u64,
}

#[derive(Clone, Copy, Serialize)]
struct Sample {
    elapsed_ns: u64,
    ops_per_sec: f64,
    #[serde(skip_serializing_if = "is_zero_u64")]
    latency_p50_us: u64,
    #[serde(skip_serializing_if = "is_zero_u64")]
    latency_p95_us: u64,
    #[serde(skip_serializing_if = "is_zero_u64")]
    latency_p99_us: u64,
}

fn is_zero_u64(v: &u64) -> bool {
    *v == 0
}

#[derive(Serialize)]
struct ScenarioRow {
    scenario_name: &'static str,
    task_count: usize,
    submitter_count: usize,
    worker_count: usize,
    median_elapsed_ns: u64,
    median_ops_per_sec: f64,
    stddev_ops_per_sec: f64,
    sample_count: usize,
    warmup_discarded: usize,
    samples: Vec<Sample>,
    latency_p50_us: u64,
    latency_p95_us: u64,
    latency_p99_us: u64,
}

#[derive(Serialize)]
struct RuntimeDocument {
    runtime_name: &'static str,
    runtime_version: String,
    source_commit: String,
    generated_at_unix_s: i64,
    host_os: &'static str,
    host_arch: &'static str,
    rows: Vec<ScenarioRow>,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = parse_args()?;
    if args.warmup_discard >= args.samples {
        return Err("warmup-discard must be smaller than samples".into());
    }

    let worker_count = thread::available_parallelism()
        .map(|value| value.get())
        .unwrap_or(1);
    let source_commit = args
        .source_commit
        .clone()
        .unwrap_or_else(|| "unknown".to_string());

    let rows = vec![
        measure_scenario("flood_1m", FLOOD_TASK_COUNT, 1, worker_count, args.samples, args.warmup_discard, run_flood_sample)?,
        measure_scenario("contended_spawn_8x", CONTENDED_TASK_COUNT, CONTENDED_SUBMITTERS, worker_count, args.samples, args.warmup_discard, run_contended_sample)?,
        measure_scenario("cpu_work_10us", 10_000, 1, worker_count, args.samples, args.warmup_discard, run_cpu_work_10us_sample)?,
        measure_scenario("cpu_work_100us", 2_000, 1, worker_count, args.samples, args.warmup_discard, run_cpu_work_100us_sample)?,
        measure_scenario("contended_cpu_10us", 10_000, 4, worker_count, args.samples, args.warmup_discard, run_contended_cpu_10us_sample)?,
        measure_scenario("nested_fanout_4x", 10_000, 1, worker_count, args.samples, args.warmup_discard, run_nested_fanout_4x_sample)?,
        measure_scenario("burst_drain_burst", 4_000, 1, worker_count, args.samples, args.warmup_discard, run_burst_drain_burst_sample)?,
        measure_scenario("mixed_fast_slow", 5_000, 1, worker_count, args.samples, args.warmup_discard, run_mixed_fast_slow_sample)?,
    ];

    let document = RuntimeDocument {
        runtime_name: "tokio",
        runtime_version: args.runtime_version,
        source_commit,
        generated_at_unix_s: unix_timestamp_now()?,
        host_os: env::consts::OS,
        host_arch: env::consts::ARCH,
        rows,
    };

    if let Some(path) = args.output_path {
        let file = File::create(path)?;
        serde_json::to_writer_pretty(file, &document)?;
    } else {
        let stdout = io::stdout();
        let mut handle = stdout.lock();
        serde_json::to_writer_pretty(&mut handle, &document)?;
        handle.write_all(b"\n")?;
    }

    Ok(())
}

fn parse_args() -> Result<Args, Box<dyn std::error::Error>> {
    let mut parsed = Args {
        output_path: None,
        runtime_version: "unknown".to_string(),
        source_commit: None,
        samples: 7,
        warmup_discard: 1,
    };

    let mut iter = env::args().skip(1);
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--output" => parsed.output_path = Some(next_value(&mut iter, "--output")?),
            "--runtime-version" => {
                parsed.runtime_version = next_value(&mut iter, "--runtime-version")?
            }
            "--source-commit" => {
                parsed.source_commit = Some(next_value(&mut iter, "--source-commit")?)
            }
            "--samples" => parsed.samples = next_value(&mut iter, "--samples")?.parse()?,
            "--warmup-discard" => {
                parsed.warmup_discard = next_value(&mut iter, "--warmup-discard")?.parse()?
            }
            _ => return Err(format!("unrecognized argument: {arg}").into()),
        }
    }

    Ok(parsed)
}

fn next_value(
    iter: &mut impl Iterator<Item = String>,
    flag: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    iter.next()
        .ok_or_else(|| format!("missing value for {flag}").into())
}

fn measure_scenario(
    scenario_name: &'static str,
    task_count: usize,
    submitter_count: usize,
    worker_count: usize,
    run_count: usize,
    warmup_discard: usize,
    run_once: fn(usize) -> Result<SampleResult, Box<dyn std::error::Error>>,
) -> Result<ScenarioRow, Box<dyn std::error::Error>> {
    let mut samples = Vec::with_capacity(run_count);
    for _ in 0..run_count {
        let r = run_once(worker_count)?;
        let ops_per_sec = task_count as f64 / (r.elapsed_ns as f64 / 1_000_000_000.0);
        samples.push(Sample {
            elapsed_ns: r.elapsed_ns,
            ops_per_sec,
            latency_p50_us: r.latency_p50_us,
            latency_p95_us: r.latency_p95_us,
            latency_p99_us: r.latency_p99_us,
        });
    }

    let mut retained = samples.split_off(warmup_discard);
    retained.sort_by(|lhs, rhs| lhs.ops_per_sec.total_cmp(&rhs.ops_per_sec));

    let median = retained[retained.len() / 2];
    let stddev_ops_per_sec = stddev_from_median(&retained, median.ops_per_sec);

    eprint!(
        "tokio {scenario_name} median_ops_per_sec={:.0} stddev={:.0} workers={worker_count}",
        median.ops_per_sec, stddev_ops_per_sec
    );
    if median.latency_p50_us > 0 {
        eprint!(
            " p50={}us p95={}us p99={}us",
            median.latency_p50_us, median.latency_p95_us, median.latency_p99_us
        );
    }
    eprintln!();

    Ok(ScenarioRow {
        scenario_name,
        task_count,
        submitter_count,
        worker_count,
        median_elapsed_ns: median.elapsed_ns,
        median_ops_per_sec: median.ops_per_sec,
        stddev_ops_per_sec,
        sample_count: retained.len(),
        warmup_discarded: warmup_discard,
        samples: retained,
        latency_p50_us: median.latency_p50_us,
        latency_p95_us: median.latency_p95_us,
        latency_p99_us: median.latency_p99_us,
    })
}

// --- Existing scenarios (no per-task latency) ---

fn run_flood_sample(worker_count: usize) -> Result<SampleResult, Box<dyn std::error::Error>> {
    let runtime = build_runtime(worker_count)?;
    let notify = Arc::new(Notify::new());
    let completed = Arc::new(AtomicUsize::new(0));
    let handle = runtime.handle().clone();
    let start = Instant::now();

    for _ in 0..FLOOD_TASK_COUNT {
        let notify = notify.clone();
        let completed = completed.clone();
        handle.spawn(async move {
            if completed.fetch_add(1, Ordering::Relaxed) + 1 == FLOOD_TASK_COUNT {
                notify.notify_one();
            }
        });
    }

    wait_for_completion(&runtime, &notify, &completed, FLOOD_TASK_COUNT);
    Ok(SampleResult {
        elapsed_ns: start.elapsed().as_nanos() as u64,
        ..Default::default()
    })
}

fn run_contended_sample(
    worker_count: usize,
) -> Result<SampleResult, Box<dyn std::error::Error>> {
    let runtime = build_runtime(worker_count)?;
    let notify = Arc::new(Notify::new());
    let completed = Arc::new(AtomicUsize::new(0));
    let handle = runtime.handle().clone();
    let per_submitter = CONTENDED_TASK_COUNT / CONTENDED_SUBMITTERS;
    let start = Instant::now();

    let mut submitters = Vec::with_capacity(CONTENDED_SUBMITTERS);
    for _ in 0..CONTENDED_SUBMITTERS {
        let handle = handle.clone();
        let notify = notify.clone();
        let completed = completed.clone();
        submitters.push(thread::spawn(move || {
            for _ in 0..per_submitter {
                let notify = notify.clone();
                let completed = completed.clone();
                handle.spawn(async move {
                    if completed.fetch_add(1, Ordering::Relaxed) + 1 == CONTENDED_TASK_COUNT {
                        notify.notify_one();
                    }
                });
            }
        }));
    }

    for submitter in submitters {
        submitter.join().map_err(|_| "submitter thread panicked")?;
    }

    wait_for_completion(&runtime, &notify, &completed, CONTENDED_TASK_COUNT);
    Ok(SampleResult {
        elapsed_ns: start.elapsed().as_nanos() as u64,
        ..Default::default()
    })
}

// --- Realistic scenarios (with per-task latency) ---

fn run_cpu_work_10us_sample(
    worker_count: usize,
) -> Result<SampleResult, Box<dyn std::error::Error>> {
    run_cpu_work_scenario(worker_count, 10_000, 10_000, 1)
}

fn run_cpu_work_100us_sample(
    worker_count: usize,
) -> Result<SampleResult, Box<dyn std::error::Error>> {
    run_cpu_work_scenario(worker_count, 2_000, 100_000, 1)
}

fn run_contended_cpu_10us_sample(
    worker_count: usize,
) -> Result<SampleResult, Box<dyn std::error::Error>> {
    run_cpu_work_scenario(worker_count, 10_000, 10_000, 4)
}

fn run_cpu_work_scenario(
    worker_count: usize,
    task_count: usize,
    work_ns: u64,
    submitters: usize,
) -> Result<SampleResult, Box<dyn std::error::Error>> {
    let runtime = build_runtime(worker_count)?;
    let handle = runtime.handle().clone();
    let notify = Arc::new(Notify::new());
    let completed_count = Arc::new(AtomicUsize::new(0));
    let submitted_at: Arc<Vec<AtomicU64>> =
        Arc::new((0..task_count).map(|_| AtomicU64::new(0)).collect());
    let completed_at: Arc<Vec<AtomicU64>> =
        Arc::new((0..task_count).map(|_| AtomicU64::new(0)).collect());

    let start = Instant::now();

    if submitters <= 1 {
        for i in 0..task_count {
            submitted_at[i].store(start.elapsed().as_nanos() as u64, Ordering::Relaxed);
            let completed_at = completed_at.clone();
            let completed_count = completed_count.clone();
            let notify = notify.clone();
            let epoch = start;
            handle.spawn(async move {
                busy_work(work_ns);
                completed_at[i].store(epoch.elapsed().as_nanos() as u64, Ordering::Relaxed);
                if completed_count.fetch_add(1, Ordering::Relaxed) + 1 == task_count {
                    notify.notify_one();
                }
            });
        }
    } else {
        let per_submitter = task_count / submitters;
        let mut threads = Vec::with_capacity(submitters);
        for s in 0..submitters {
            let offset = s * per_submitter;
            let handle = handle.clone();
            let submitted_at = submitted_at.clone();
            let completed_at = completed_at.clone();
            let completed_count = completed_count.clone();
            let notify = notify.clone();
            let epoch = start;
            threads.push(thread::spawn(move || {
                for j in 0..per_submitter {
                    let idx = offset + j;
                    submitted_at[idx].store(epoch.elapsed().as_nanos() as u64, Ordering::Relaxed);
                    let completed_at = completed_at.clone();
                    let completed_count = completed_count.clone();
                    let notify = notify.clone();
                    handle.spawn(async move {
                        busy_work(work_ns);
                        completed_at[idx]
                            .store(epoch.elapsed().as_nanos() as u64, Ordering::Relaxed);
                        if completed_count.fetch_add(1, Ordering::Relaxed) + 1 == task_count {
                            notify.notify_one();
                        }
                    });
                }
            }));
        }
        for t in threads {
            t.join().map_err(|_| "submitter thread panicked")?;
        }
    }

    wait_for_completion(&runtime, &notify, &completed_count, task_count);
    let elapsed_ns = start.elapsed().as_nanos() as u64;

    let mut latencies: Vec<u64> = (0..task_count)
        .map(|i| {
            let s = submitted_at[i].load(Ordering::Relaxed);
            let c = completed_at[i].load(Ordering::Relaxed);
            c.saturating_sub(s)
        })
        .collect();
    let (p50, p95, p99) = compute_percentiles(&mut latencies);

    Ok(SampleResult {
        elapsed_ns,
        latency_p50_us: p50 / 1000,
        latency_p95_us: p95 / 1000,
        latency_p99_us: p99 / 1000,
    })
}

fn run_nested_fanout_4x_sample(
    worker_count: usize,
) -> Result<SampleResult, Box<dyn std::error::Error>> {
    let runtime = build_runtime(worker_count)?;
    let handle = runtime.handle().clone();

    const PARENT_COUNT: usize = 2_000;
    const CHILDREN_PER_PARENT: usize = 4;
    const TOTAL_TASKS: usize = PARENT_COUNT + PARENT_COUNT * CHILDREN_PER_PARENT;

    let notify = Arc::new(Notify::new());
    let completed_count = Arc::new(AtomicUsize::new(0));
    let submitted_at: Arc<Vec<AtomicU64>> =
        Arc::new((0..TOTAL_TASKS).map(|_| AtomicU64::new(0)).collect());
    let completed_at: Arc<Vec<AtomicU64>> =
        Arc::new((0..TOTAL_TASKS).map(|_| AtomicU64::new(0)).collect());

    let start = Instant::now();

    for i in 0..PARENT_COUNT {
        submitted_at[i].store(start.elapsed().as_nanos() as u64, Ordering::Relaxed);
        let child_handle = handle.clone();
        let submitted_at = submitted_at.clone();
        let completed_at = completed_at.clone();
        let completed_count = completed_count.clone();
        let notify = notify.clone();
        let epoch = start;
        handle.spawn(async move {
            completed_at[i].store(epoch.elapsed().as_nanos() as u64, Ordering::Relaxed);
            if completed_count.fetch_add(1, Ordering::Relaxed) + 1 == TOTAL_TASKS {
                notify.notify_one();
            }
            for c in 0..CHILDREN_PER_PARENT {
                let child_idx = PARENT_COUNT + i * CHILDREN_PER_PARENT + c;
                submitted_at[child_idx]
                    .store(epoch.elapsed().as_nanos() as u64, Ordering::Relaxed);
                let completed_at = completed_at.clone();
                let completed_count = completed_count.clone();
                let notify = notify.clone();
                child_handle.spawn(async move {
                    completed_at[child_idx]
                        .store(epoch.elapsed().as_nanos() as u64, Ordering::Relaxed);
                    if completed_count.fetch_add(1, Ordering::Relaxed) + 1 == TOTAL_TASKS {
                        notify.notify_one();
                    }
                });
            }
        });
    }

    wait_for_completion(&runtime, &notify, &completed_count, TOTAL_TASKS);
    let elapsed_ns = start.elapsed().as_nanos() as u64;

    let mut latencies: Vec<u64> = (0..TOTAL_TASKS)
        .map(|i| {
            let s = submitted_at[i].load(Ordering::Relaxed);
            let c = completed_at[i].load(Ordering::Relaxed);
            c.saturating_sub(s)
        })
        .collect();
    let (p50, p95, p99) = compute_percentiles(&mut latencies);

    Ok(SampleResult {
        elapsed_ns,
        latency_p50_us: p50 / 1000,
        latency_p95_us: p95 / 1000,
        latency_p99_us: p99 / 1000,
    })
}

fn run_burst_drain_burst_sample(
    worker_count: usize,
) -> Result<SampleResult, Box<dyn std::error::Error>> {
    let runtime = build_runtime(worker_count)?;
    let handle = runtime.handle().clone();

    const TASK_COUNT: usize = 4_000;
    const WORK_NS: u64 = 50_000;
    const IDLE_GAP: std::time::Duration = std::time::Duration::from_millis(10);
    let half = TASK_COUNT / 2;

    let submitted_at: Arc<Vec<AtomicU64>> =
        Arc::new((0..TASK_COUNT).map(|_| AtomicU64::new(0)).collect());
    let completed_at: Arc<Vec<AtomicU64>> =
        Arc::new((0..TASK_COUNT).map(|_| AtomicU64::new(0)).collect());

    let start = Instant::now();

    // First burst
    let notify1 = Arc::new(Notify::new());
    let count1 = Arc::new(AtomicUsize::new(0));
    for i in 0..half {
        submitted_at[i].store(start.elapsed().as_nanos() as u64, Ordering::Relaxed);
        let completed_at = completed_at.clone();
        let count1 = count1.clone();
        let notify1 = notify1.clone();
        let epoch = start;
        handle.spawn(async move {
            busy_work(WORK_NS);
            completed_at[i].store(epoch.elapsed().as_nanos() as u64, Ordering::Relaxed);
            if count1.fetch_add(1, Ordering::Relaxed) + 1 == half {
                notify1.notify_one();
            }
        });
    }
    wait_for_completion(&runtime, &notify1, &count1, half);

    thread::sleep(IDLE_GAP);

    // Second burst
    let notify2 = Arc::new(Notify::new());
    let count2 = Arc::new(AtomicUsize::new(0));
    let second_half = TASK_COUNT - half;
    for i in half..TASK_COUNT {
        submitted_at[i].store(start.elapsed().as_nanos() as u64, Ordering::Relaxed);
        let completed_at = completed_at.clone();
        let count2 = count2.clone();
        let notify2 = notify2.clone();
        let epoch = start;
        handle.spawn(async move {
            busy_work(WORK_NS);
            completed_at[i].store(epoch.elapsed().as_nanos() as u64, Ordering::Relaxed);
            if count2.fetch_add(1, Ordering::Relaxed) + 1 == second_half {
                notify2.notify_one();
            }
        });
    }
    wait_for_completion(&runtime, &notify2, &count2, second_half);

    thread::sleep(IDLE_GAP);

    let elapsed_ns = start.elapsed().as_nanos() as u64;

    let mut latencies: Vec<u64> = (0..TASK_COUNT)
        .map(|i| {
            let s = submitted_at[i].load(Ordering::Relaxed);
            let c = completed_at[i].load(Ordering::Relaxed);
            c.saturating_sub(s)
        })
        .collect();
    let (p50, p95, p99) = compute_percentiles(&mut latencies);

    Ok(SampleResult {
        elapsed_ns,
        latency_p50_us: p50 / 1000,
        latency_p95_us: p95 / 1000,
        latency_p99_us: p99 / 1000,
    })
}

fn run_mixed_fast_slow_sample(
    worker_count: usize,
) -> Result<SampleResult, Box<dyn std::error::Error>> {
    let runtime = build_runtime(worker_count)?;
    let handle = runtime.handle().clone();

    const TASK_COUNT: usize = 5_000;
    const SLOW_NS: u64 = 1_000_000;

    let notify = Arc::new(Notify::new());
    let completed_count = Arc::new(AtomicUsize::new(0));
    let submitted_at: Arc<Vec<AtomicU64>> =
        Arc::new((0..TASK_COUNT).map(|_| AtomicU64::new(0)).collect());
    let completed_at: Arc<Vec<AtomicU64>> =
        Arc::new((0..TASK_COUNT).map(|_| AtomicU64::new(0)).collect());

    let start = Instant::now();

    for i in 0..TASK_COUNT {
        let is_slow = (i % 5) == 0;
        submitted_at[i].store(start.elapsed().as_nanos() as u64, Ordering::Relaxed);
        let completed_at = completed_at.clone();
        let completed_count = completed_count.clone();
        let notify = notify.clone();
        let epoch = start;
        handle.spawn(async move {
            if is_slow {
                busy_work(SLOW_NS);
            }
            completed_at[i].store(epoch.elapsed().as_nanos() as u64, Ordering::Relaxed);
            if completed_count.fetch_add(1, Ordering::Relaxed) + 1 == TASK_COUNT {
                notify.notify_one();
            }
        });
    }

    wait_for_completion(&runtime, &notify, &completed_count, TASK_COUNT);
    let elapsed_ns = start.elapsed().as_nanos() as u64;

    let mut latencies: Vec<u64> = (0..TASK_COUNT)
        .map(|i| {
            let s = submitted_at[i].load(Ordering::Relaxed);
            let c = completed_at[i].load(Ordering::Relaxed);
            c.saturating_sub(s)
        })
        .collect();
    let (p50, p95, p99) = compute_percentiles(&mut latencies);

    Ok(SampleResult {
        elapsed_ns,
        latency_p50_us: p50 / 1000,
        latency_p95_us: p95 / 1000,
        latency_p99_us: p99 / 1000,
    })
}

// --- Helpers ---

fn build_runtime(worker_count: usize) -> Result<Runtime, Box<dyn std::error::Error>> {
    Ok(Builder::new_multi_thread()
        .worker_threads(worker_count)
        .enable_all()
        .build()?)
}

fn wait_for_completion(
    runtime: &Runtime,
    notify: &Arc<Notify>,
    completed: &Arc<AtomicUsize>,
    target: usize,
) {
    runtime.block_on(async {
        if completed.load(Ordering::Relaxed) < target {
            notify.notified().await;
        }
    });
}

fn busy_work(ns: u64) {
    let start = Instant::now();
    while start.elapsed().as_nanos() < ns as u128 {}
}

fn compute_percentiles(latencies: &mut [u64]) -> (u64, u64, u64) {
    if latencies.is_empty() {
        return (0, 0, 0);
    }
    latencies.sort_unstable();
    let n = latencies.len();
    (
        latencies[n * 50 / 100],
        latencies[(n * 95 / 100).min(n - 1)],
        latencies[(n * 99 / 100).min(n - 1)],
    )
}

fn stddev_from_median(samples: &[Sample], median_ops_per_sec: f64) -> f64 {
    let sum_sq = samples
        .iter()
        .map(|sample| {
            let delta = sample.ops_per_sec - median_ops_per_sec;
            delta * delta
        })
        .sum::<f64>();
    (sum_sq / samples.len() as f64).sqrt()
}

fn unix_timestamp_now() -> Result<i64, Box<dyn std::error::Error>> {
    Ok(std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs() as i64)
}
