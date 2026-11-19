// Command benchscratchgo is the Go side of the Scratch micro-benchmark
// (bench/bench_scratch.zig): it times regexp.MatchString, which pools its
// *machine in a sync.Pool (zero-allocation steady state, the equivalent of
// a reused Scratch), on the cases in bench/data/scratch.jsonl with the same
// 200 ms calibration. Build it as a binary (tools/bench.sh does this):
//
//	go build -o benchscratchgo ./cmd/benchscratchgo && ./benchscratchgo -data ../bench/data
//
// Output (stdout, TSV with a header line):  name go_ns result
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"path/filepath"
	"regexp"
	"time"

	"zoptia0regex/tools/internal/gen"
)

// ScratchCase mirrors cmd/genbench's ScratchCase.
type ScratchCase struct {
	Name string `json:"name"`
	P    string `json:"p"`
	In   string `json:"in"`
}

const calibrateNs = 200_000_000

var sink uint64

// batches is how many batches are timed at the calibrated iteration count.
// The fastest one is reported, so a burst of background load cannot inflate
// a row.
const batches = 5

// calibrate doubles the iteration count until one batch exceeds
// calibrateNs, times batches batches in all at that count and returns the
// fastest batch's ns per call.
func calibrate(fn func() uint64) float64 {
	run := func(iters int64) int64 {
		start := time.Now()
		var acc uint64
		for i := int64(0); i < iters; i++ {
			acc += fn()
		}
		ns := time.Since(start).Nanoseconds()
		sink += acc
		return ns
	}
	iters := int64(1)
	best := run(iters)
	for best <= calibrateNs {
		iters *= 2
		best = run(iters)
	}
	for k := 1; k < batches; k++ {
		best = min(best, run(iters))
	}
	return float64(best) / float64(iters)
}

func main() {
	dir := flag.String("data", "bench/data", "directory holding scratch.jsonl")
	flag.Parse()
	out := gen.Stdout()
	fmt.Fprintln(out, "name\tgo_ns\tresult")
	sc := bufio.NewScanner(bytes.NewReader(gen.ReadFile(filepath.Join(*dir, "scratch.jsonl"))))
	for sc.Scan() {
		var c ScratchCase
		gen.Check(json.Unmarshal(sc.Bytes(), &c))
		re := regexp.MustCompile(c.P)
		match := func() uint64 {
			if re.MatchString(c.In) {
				return 1
			}
			return 0
		}
		result := match()
		ns := calibrate(match)
		fmt.Fprintf(out, "%s\t%.1f\t%d\n", c.Name, ns, result)
	}
	gen.Check(sc.Err())
	out.Close()
}
