// Go-side counterpart to src/bench_scratch.zig: times Go's regexp.MatchString
// (which pools its *machine via sync.Pool — zero-allocation steady state, the
// equivalent of our reused Scratch) on the exact same patterns/inputs, with the
// same 200ms calibration. Run from tools/:  go run bench_scratch_go.go
package main

import (
	"fmt"
	"regexp"
	"time"
)

const calibrateNs = 200_000_000

func calibrate(fn func() uint64) float64 {
	iters := uint64(1)
	for {
		start := time.Now()
		var acc uint64
		for i := uint64(0); i < iters; i++ {
			acc += fn()
		}
		ns := time.Since(start).Nanoseconds()
		if ns > calibrateNs {
			_ = acc
			return float64(ns) / float64(iters)
		}
		iters *= 2
	}
}

func main() {
	cases := []struct{ name, p, in string }{
		{"literal-needle", "needle", "a haystack with a needle hidden somewhere near the end"},
		{"alternation", "(foo|bar|baz)+", "zz bar foo baz qux barbaz zz"},
		{"email-unanchored", "[a-z]+@[a-z]+\\.[a-z]+", "please contact us at user@example.com today"},
		{"charclass-plus", "[0-9]+", "order 12345 shipped on 2024"},
		{"anchored-onepass", `\A\d+\z`, "1234567890"},
	}
	fmt.Println("name\tgo_ns")
	for _, c := range cases {
		re := regexp.MustCompile(c.p)
		input := c.in
		ns := calibrate(func() uint64 {
			if re.MatchString(input) {
				return 1
			}
			return 0
		})
		fmt.Printf("%s\t%.0f\n", c.name, ns)
	}
}
