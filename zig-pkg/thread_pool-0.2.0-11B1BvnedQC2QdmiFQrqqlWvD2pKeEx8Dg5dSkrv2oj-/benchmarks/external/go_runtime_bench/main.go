package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"runtime"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

const (
	floodTaskCount      = 1_000_000
	contendedTaskCount  = 100_000
	contendedSubmitters = 8
)

type sampleResult struct {
	elapsedNs    uint64
	latencyP50Us uint64
	latencyP95Us uint64
	latencyP99Us uint64
}

type sample struct {
	ElapsedNS    uint64  `json:"elapsed_ns"`
	OpsPerSec    float64 `json:"ops_per_sec"`
	LatencyP50Us uint64  `json:"latency_p50_us,omitempty"`
	LatencyP95Us uint64  `json:"latency_p95_us,omitempty"`
	LatencyP99Us uint64  `json:"latency_p99_us,omitempty"`
}

type scenarioRow struct {
	ScenarioName    string   `json:"scenario_name"`
	TaskCount       int      `json:"task_count"`
	SubmitterCount  int      `json:"submitter_count"`
	WorkerCount     int      `json:"worker_count"`
	MedianElapsedNS uint64   `json:"median_elapsed_ns"`
	MedianOpsPerSec float64  `json:"median_ops_per_sec"`
	StddevOpsPerSec float64  `json:"stddev_ops_per_sec"`
	SampleCount     int      `json:"sample_count"`
	WarmupDiscarded int      `json:"warmup_discarded"`
	Samples         []sample `json:"samples"`
	LatencyP50Us    uint64   `json:"latency_p50_us"`
	LatencyP95Us    uint64   `json:"latency_p95_us"`
	LatencyP99Us    uint64   `json:"latency_p99_us"`
}

type runtimeDocument struct {
	RuntimeName      string        `json:"runtime_name"`
	RuntimeVersion   string        `json:"runtime_version"`
	SourceCommit     string        `json:"source_commit"`
	GeneratedAtUnixS int64         `json:"generated_at_unix_s"`
	HostOS           string        `json:"host_os"`
	HostArch         string        `json:"host_arch"`
	Rows             []scenarioRow `json:"rows"`
}

func main() {
	var outputPath string
	var runtimeVersion string
	var sourceCommit string
	var samples int
	var warmupDiscard int

	flag.StringVar(&outputPath, "output", "", "write JSON to this file instead of stdout")
	flag.StringVar(&runtimeVersion, "runtime-version", runtime.Version(), "runtime version label")
	flag.StringVar(&sourceCommit, "source-commit", "unknown", "source commit label")
	flag.IntVar(&samples, "samples", 7, "number of total runs to execute")
	flag.IntVar(&warmupDiscard, "warmup-discard", 1, "number of initial runs to discard")
	flag.Parse()

	if warmupDiscard >= samples {
		fmt.Fprintln(os.Stderr, "warmup-discard must be smaller than samples")
		os.Exit(2)
	}

	workerCount := runtime.NumCPU()
	rows := []scenarioRow{
		mustMeasureScenario("flood_1m", floodTaskCount, 1, workerCount, samples, warmupDiscard, runFloodSample),
		mustMeasureScenario("contended_spawn_8x", contendedTaskCount, contendedSubmitters, workerCount, samples, warmupDiscard, runContendedSample),
		mustMeasureScenario("cpu_work_10us", 10_000, 1, workerCount, samples, warmupDiscard, runCpuWork10usSample),
		mustMeasureScenario("cpu_work_100us", 2_000, 1, workerCount, samples, warmupDiscard, runCpuWork100usSample),
		mustMeasureScenario("contended_cpu_10us", 10_000, 4, workerCount, samples, warmupDiscard, runContendedCpu10usSample),
		mustMeasureScenario("nested_fanout_4x", 10_000, 1, workerCount, samples, warmupDiscard, runNestedFanout4xSample),
		mustMeasureScenario("burst_drain_burst", 4_000, 1, workerCount, samples, warmupDiscard, runBurstDrainBurstSample),
		mustMeasureScenario("mixed_fast_slow", 5_000, 1, workerCount, samples, warmupDiscard, runMixedFastSlowSample),
	}

	document := runtimeDocument{
		RuntimeName:      "go",
		RuntimeVersion:   runtimeVersion,
		SourceCommit:     sourceCommit,
		GeneratedAtUnixS: time.Now().Unix(),
		HostOS:           runtime.GOOS,
		HostArch:         runtime.GOARCH,
		Rows:             rows,
	}

	var (
		writer *os.File
		err    error
	)
	if outputPath != "" {
		writer, err = os.Create(outputPath)
	} else {
		writer = os.Stdout
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if outputPath != "" {
		defer writer.Close()
	}

	encoder := json.NewEncoder(writer)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(document); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func mustMeasureScenario(
	scenarioName string,
	taskCount int,
	submitterCount int,
	workerCount int,
	runCount int,
	warmupDiscard int,
	runOnce func(int) sampleResult,
) scenarioRow {
	allSamples := make([]sample, 0, runCount)
	for i := 0; i < runCount; i++ {
		r := runOnce(workerCount)
		opsPerSec := float64(taskCount) / (float64(r.elapsedNs) / 1_000_000_000.0)
		allSamples = append(allSamples, sample{
			ElapsedNS:    r.elapsedNs,
			OpsPerSec:    opsPerSec,
			LatencyP50Us: r.latencyP50Us,
			LatencyP95Us: r.latencyP95Us,
			LatencyP99Us: r.latencyP99Us,
		})
	}

	retained := append([]sample(nil), allSamples[warmupDiscard:]...)
	sort.Slice(retained, func(i, j int) bool {
		return retained[i].OpsPerSec < retained[j].OpsPerSec
	})

	median := retained[len(retained)/2]
	stddevOpsPerSec := stddevFromMedian(retained, median.OpsPerSec)

	fmt.Fprintf(
		os.Stderr,
		"go %s median_ops_per_sec=%.0f stddev=%.0f workers=%d",
		scenarioName,
		median.OpsPerSec,
		stddevOpsPerSec,
		workerCount,
	)
	if median.LatencyP50Us > 0 {
		fmt.Fprintf(os.Stderr, " p50=%dus p95=%dus p99=%dus",
			median.LatencyP50Us, median.LatencyP95Us, median.LatencyP99Us)
	}
	fmt.Fprintln(os.Stderr)

	return scenarioRow{
		ScenarioName:    scenarioName,
		TaskCount:       taskCount,
		SubmitterCount:  submitterCount,
		WorkerCount:     workerCount,
		MedianElapsedNS: median.ElapsedNS,
		MedianOpsPerSec: median.OpsPerSec,
		StddevOpsPerSec: stddevOpsPerSec,
		SampleCount:     len(retained),
		WarmupDiscarded: warmupDiscard,
		Samples:         retained,
		LatencyP50Us:    median.LatencyP50Us,
		LatencyP95Us:    median.LatencyP95Us,
		LatencyP99Us:    median.LatencyP99Us,
	}
}

// --- Existing scenarios (no per-task latency) ---

func runFloodSample(workerCount int) sampleResult {
	runtime.GOMAXPROCS(workerCount)

	var marker atomic.Uint64
	var wg sync.WaitGroup
	wg.Add(floodTaskCount)
	start := time.Now()

	for i := 0; i < floodTaskCount; i++ {
		go func() {
			marker.Add(1)
			wg.Done()
		}()
	}

	wg.Wait()
	return sampleResult{elapsedNs: uint64(time.Since(start).Nanoseconds())}
}

func runContendedSample(workerCount int) sampleResult {
	runtime.GOMAXPROCS(workerCount)

	perSubmitter := contendedTaskCount / contendedSubmitters
	var marker atomic.Uint64
	var taskWait sync.WaitGroup
	var submitterWait sync.WaitGroup
	taskWait.Add(contendedTaskCount)
	submitterWait.Add(contendedSubmitters)

	start := time.Now()
	for i := 0; i < contendedSubmitters; i++ {
		go func() {
			defer submitterWait.Done()
			for j := 0; j < perSubmitter; j++ {
				go func() {
					marker.Add(1)
					taskWait.Done()
				}()
			}
		}()
	}

	submitterWait.Wait()
	taskWait.Wait()
	return sampleResult{elapsedNs: uint64(time.Since(start).Nanoseconds())}
}

// --- Realistic scenarios (with per-task latency) ---

func runCpuWork10usSample(workerCount int) sampleResult {
	return runCpuWorkScenario(workerCount, 10_000, 10_000, 1)
}

func runCpuWork100usSample(workerCount int) sampleResult {
	return runCpuWorkScenario(workerCount, 2_000, 100_000, 1)
}

func runContendedCpu10usSample(workerCount int) sampleResult {
	return runCpuWorkScenario(workerCount, 10_000, 10_000, 4)
}

func runCpuWorkScenario(workerCount int, taskCount int, workNs int64, submitters int) sampleResult {
	runtime.GOMAXPROCS(workerCount)

	submittedAt := make([]int64, taskCount)
	completedAt := make([]int64, taskCount)
	var taskWg sync.WaitGroup
	taskWg.Add(taskCount)

	start := time.Now()

	if submitters <= 1 {
		for i := 0; i < taskCount; i++ {
			submittedAt[i] = time.Now().UnixNano()
			go func(idx int) {
				busyWork(workNs)
				completedAt[idx] = time.Now().UnixNano()
				taskWg.Done()
			}(i)
		}
	} else {
		perSubmitter := taskCount / submitters
		var submitterWg sync.WaitGroup
		submitterWg.Add(submitters)
		for s := 0; s < submitters; s++ {
			offset := s * perSubmitter
			go func(off int) {
				defer submitterWg.Done()
				for j := 0; j < perSubmitter; j++ {
					idx := off + j
					submittedAt[idx] = time.Now().UnixNano()
					go func(i int) {
						busyWork(workNs)
						completedAt[i] = time.Now().UnixNano()
						taskWg.Done()
					}(idx)
				}
			}(offset)
		}
		submitterWg.Wait()
	}

	taskWg.Wait()
	elapsed := uint64(time.Since(start).Nanoseconds())

	latencies := make([]uint64, taskCount)
	for i := range latencies {
		if completedAt[i] > submittedAt[i] {
			latencies[i] = uint64(completedAt[i] - submittedAt[i])
		}
	}
	p50, p95, p99 := computePercentiles(latencies)
	return sampleResult{
		elapsedNs:    elapsed,
		latencyP50Us: p50 / 1000,
		latencyP95Us: p95 / 1000,
		latencyP99Us: p99 / 1000,
	}
}

func runNestedFanout4xSample(workerCount int) sampleResult {
	runtime.GOMAXPROCS(workerCount)

	const parentCount = 2_000
	const childrenPerParent = 4
	const totalTasks = parentCount + parentCount*childrenPerParent

	submittedAt := make([]int64, totalTasks)
	completedAt := make([]int64, totalTasks)
	var wg sync.WaitGroup
	wg.Add(totalTasks)

	start := time.Now()
	for i := 0; i < parentCount; i++ {
		submittedAt[i] = time.Now().UnixNano()
		go func(parentIdx int) {
			completedAt[parentIdx] = time.Now().UnixNano()
			wg.Done()
			for c := 0; c < childrenPerParent; c++ {
				childIdx := parentCount + parentIdx*childrenPerParent + c
				submittedAt[childIdx] = time.Now().UnixNano()
				go func(ci int) {
					completedAt[ci] = time.Now().UnixNano()
					wg.Done()
				}(childIdx)
			}
		}(i)
	}
	wg.Wait()
	elapsed := uint64(time.Since(start).Nanoseconds())

	latencies := make([]uint64, totalTasks)
	for i := range latencies {
		if completedAt[i] > submittedAt[i] {
			latencies[i] = uint64(completedAt[i] - submittedAt[i])
		}
	}
	p50, p95, p99 := computePercentiles(latencies)
	return sampleResult{
		elapsedNs:    elapsed,
		latencyP50Us: p50 / 1000,
		latencyP95Us: p95 / 1000,
		latencyP99Us: p99 / 1000,
	}
}

func runBurstDrainBurstSample(workerCount int) sampleResult {
	runtime.GOMAXPROCS(workerCount)

	const taskCount = 4_000
	const workNs int64 = 50_000
	const idleGap = 10 * time.Millisecond
	halfCount := taskCount / 2

	submittedAt := make([]int64, taskCount)
	completedAt := make([]int64, taskCount)

	start := time.Now()

	var wg sync.WaitGroup
	wg.Add(halfCount)
	for i := 0; i < halfCount; i++ {
		submittedAt[i] = time.Now().UnixNano()
		go func(idx int) {
			busyWork(workNs)
			completedAt[idx] = time.Now().UnixNano()
			wg.Done()
		}(i)
	}
	wg.Wait()

	time.Sleep(idleGap)

	wg.Add(taskCount - halfCount)
	for i := halfCount; i < taskCount; i++ {
		submittedAt[i] = time.Now().UnixNano()
		go func(idx int) {
			busyWork(workNs)
			completedAt[idx] = time.Now().UnixNano()
			wg.Done()
		}(i)
	}
	wg.Wait()

	time.Sleep(idleGap)

	elapsed := uint64(time.Since(start).Nanoseconds())

	latencies := make([]uint64, taskCount)
	for i := range latencies {
		if completedAt[i] > submittedAt[i] {
			latencies[i] = uint64(completedAt[i] - submittedAt[i])
		}
	}
	p50, p95, p99 := computePercentiles(latencies)
	return sampleResult{
		elapsedNs:    elapsed,
		latencyP50Us: p50 / 1000,
		latencyP95Us: p95 / 1000,
		latencyP99Us: p99 / 1000,
	}
}

func runMixedFastSlowSample(workerCount int) sampleResult {
	runtime.GOMAXPROCS(workerCount)

	const taskCount = 5_000
	const slowNs int64 = 1_000_000

	submittedAt := make([]int64, taskCount)
	completedAt := make([]int64, taskCount)
	var wg sync.WaitGroup
	wg.Add(taskCount)

	start := time.Now()
	for i := 0; i < taskCount; i++ {
		isSlow := (i % 5) == 0
		submittedAt[i] = time.Now().UnixNano()
		go func(idx int, slow bool) {
			if slow {
				busyWork(slowNs)
			}
			completedAt[idx] = time.Now().UnixNano()
			wg.Done()
		}(i, isSlow)
	}
	wg.Wait()
	elapsed := uint64(time.Since(start).Nanoseconds())

	latencies := make([]uint64, taskCount)
	for i := range latencies {
		if completedAt[i] > submittedAt[i] {
			latencies[i] = uint64(completedAt[i] - submittedAt[i])
		}
	}
	p50, p95, p99 := computePercentiles(latencies)
	return sampleResult{
		elapsedNs:    elapsed,
		latencyP50Us: p50 / 1000,
		latencyP95Us: p95 / 1000,
		latencyP99Us: p99 / 1000,
	}
}

// --- Helpers ---

func busyWork(ns int64) {
	start := time.Now()
	for time.Since(start).Nanoseconds() < ns {
	}
}

func computePercentiles(latencies []uint64) (p50, p95, p99 uint64) {
	if len(latencies) == 0 {
		return 0, 0, 0
	}
	sorted := make([]uint64, len(latencies))
	copy(sorted, latencies)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	n := len(sorted)
	return sorted[n*50/100], sorted[min(n*95/100, n-1)], sorted[min(n*99/100, n-1)]
}

func stddevFromMedian(samples []sample, medianOpsPerSec float64) float64 {
	var sumSq float64
	for _, s := range samples {
		delta := s.OpsPerSec - medianOpsPerSec
		sumSq += delta * delta
	}
	return math.Sqrt(sumSq / float64(len(samples)))
}
