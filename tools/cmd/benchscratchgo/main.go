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

func calibrate(fn func() uint64) float64 {
	iters := int64(1)
	for {
		start := time.Now()
		var acc uint64
		for i := int64(0); i < iters; i++ {
			acc += fn()
		}
		ns := time.Since(start).Nanoseconds()
		sink += acc
		if ns > calibrateNs {
			return float64(ns) / float64(iters)
		}
		iters *= 2
	}
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
