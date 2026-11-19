// Command benchgo times Go's regexp package on the shared throughput cases
// (bench/data/bench.jsonl), with the same calibration as the Zig harness
// (bench/bench.zig). Build it as a binary so the timing does not include
// `go run`'s build (tools/bench.sh does this):
//
//	go build -o benchgo ./cmd/benchgo && ./benchgo -data ../bench/data > go.tsv
//
// Output (stdout, TSV with a header line):
//
//	name op engine compile_ns op_ns mb_s result
//
// result is the value of one single run of the operation (see runOp), so
// it can be compared with the Zig harness's column; engine is "-" (Go does
// not expose which engine it used).
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"path/filepath"
	"regexp"
	"runtime"
	"time"

	"zoptia0regex/tools/internal/gen"
)

// Case mirrors cmd/genbench's Case.
type Case struct {
	Name string `json:"name"`
	P    string `json:"p"`
	Op   string `json:"op"`
	In   string `json:"in"`
	Lit  string `json:"lit"`
}

const calibrateNs = 250_000_000 // grow iterations until a run exceeds 250 ms
const compileTargetNs = 100_000_000

// sink keeps every accumulated result observable.
var sink uint64

// batches is how many batches are timed at the calibrated iteration count.
// The fastest one is reported, so a burst of background load cannot inflate
// a row.
const batches = 5

// calibrate doubles the iteration count until one batch exceeds target ns,
// times batches batches in all at that count and returns the fastest
// batch's ns per call.
func calibrate(target int64, fn func() uint64) float64 {
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
	for best <= target {
		iters *= 2
		best = run(iters)
	}
	for k := 1; k < batches; k++ {
		best = min(best, run(iters))
	}
	return float64(best) / float64(iters)
}

// runOp returns a value derived from one operation's full result; the Zig
// harness computes the same value, so the result columns must agree.
func runOp(re *regexp.Regexp, op, input string) uint64 {
	switch op {
	case "match":
		if re.MatchString(input) {
			return 1
		}
		return 0
	case "find":
		loc := re.FindStringIndex(input)
		if loc == nil {
			return 0
		}
		return uint64(loc[0] + loc[1] + 1)
	case "findall":
		var sum uint64
		for _, loc := range re.FindAllStringIndex(input, -1) {
			sum += uint64(loc[0] + loc[1] + 1)
		}
		return sum
	case "submatch":
		var sum uint64
		for _, x := range re.FindStringSubmatchIndex(input) {
			sum += uint64(x + 1)
		}
		return sum
	}
	gen.Fatalf("unknown op %q", op)
	return 0
}

func main() {
	dir := flag.String("data", "bench/data", "directory holding bench.jsonl and its corpora")
	flag.Parse()
	inputs := map[string]string{
		"corpus": string(gen.ReadFile(filepath.Join(*dir, "bench_corpus.txt"))),
		"aaa":    string(gen.ReadFile(filepath.Join(*dir, "bench_aaa.txt"))),
	}
	out := gen.Stdout()
	fmt.Fprintf(out, "# go=%s os=%s arch=%s\n", runtime.Version(), runtime.GOOS, runtime.GOARCH)
	fmt.Fprintln(out, "name\top\tengine\tcompile_ns\top_ns\tmb_s\tresult")
	sc := bufio.NewScanner(bytes.NewReader(gen.ReadFile(filepath.Join(*dir, "bench.jsonl"))))
	for sc.Scan() {
		var c Case
		gen.Check(json.Unmarshal(sc.Bytes(), &c))
		input := c.Lit
		if input == "" {
			var ok bool
			if input, ok = inputs[c.In]; !ok {
				gen.Fatalf("%s: unknown input %q", c.Name, c.In)
			}
		}
		compileNs := calibrate(compileTargetNs, func() uint64 {
			return uint64(regexp.MustCompile(c.P).NumSubexp())
		})
		re := regexp.MustCompile(c.P)
		result := runOp(re, c.Op, input)
		opNs := calibrate(calibrateNs, func() uint64 { return runOp(re, c.Op, input) })
		mbps := float64(len(input)) * 1000.0 / opNs
		fmt.Fprintf(out, "%s\t%s\t-\t%.0f\t%.1f\t%.2f\t%d\n", c.Name, c.Op, compileNs, opNs, mbps, result)
	}
	gen.Check(sc.Err())
	out.Close()
}
