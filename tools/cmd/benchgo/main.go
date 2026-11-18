// Go-side benchmark harness: times Go's regexp package on the shared cases,
// using the same calibration methodology as the Zig harness (src/bench.zig).
//
//	go run benchgo.go        # run from tools/
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"
)

type Case struct {
	Name string `json:"name"`
	P    string `json:"p"`
	Op   string `json:"op"`
	In   string `json:"in"`
	Lit  string `json:"lit"`
}

const calibrateNs = 250_000_000 // grow iterations until a run exceeds 250ms

func calibrate(fn func() uint64) (nsPerOp float64, checksum uint64) {
	iters := uint64(1)
	for {
		start := time.Now()
		var acc uint64
		for i := uint64(0); i < iters; i++ {
			acc += fn()
		}
		ns := time.Since(start).Nanoseconds()
		if ns > calibrateNs {
			return float64(ns) / float64(iters), acc
		}
		iters *= 2
	}
}

func main() {
	corpus, _ := os.ReadFile("../src/bench_corpus.txt")
	aaa, _ := os.ReadFile("../src/bench_aaa.txt")
	inputs := map[string]string{"corpus": string(corpus), "aaa": string(aaa)}

	f, _ := os.Open("../src/bench.jsonl")
	defer f.Close()
	sc := bufio.NewScanner(f)
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()

	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var c Case
		json.Unmarshal(line, &c)
		input := c.Lit
		if input == "" {
			input = inputs[c.In]
		}

		// Compile timing.
		compileNs, _ := calibrate(func() uint64 {
			re := regexp.MustCompile(c.P)
			return uint64(re.NumSubexp())
		})

		re := regexp.MustCompile(c.P)
		var op func() uint64
		switch c.Op {
		case "match":
			op = func() uint64 {
				if re.MatchString(input) {
					return 1
				}
				return 0
			}
		case "find":
			op = func() uint64 {
				loc := re.FindStringIndex(input)
				if loc == nil {
					return 0
				}
				return uint64(loc[0] + loc[1])
			}
		case "findall":
			op = func() uint64 { return uint64(len(re.FindAllStringIndex(input, -1))) }
		case "submatch":
			op = func() uint64 { return uint64(len(re.FindStringSubmatchIndex(input))) }
		}

		opNs, checksum := calibrate(op)
		mbps := float64(len(input)) * 1000.0 / opNs
		fmt.Fprintf(out, "%s\t%.0f\t%.1f\t%.2f\t%d\n", c.Name, compileNs, opNs, mbps, checksum)
	}
	_ = strings.TrimSpace
}
