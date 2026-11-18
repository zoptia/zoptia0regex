// Command genfold writes src/fold_table.zig to stdout: the (from -> next)
// orbit of Go's unicode.SimpleFold for every code point whose fold differs
// from itself. Run via tools/regen.sh.
package main

import (
	"fmt"
	"os"
	"unicode"

	"zoptia0regex/tools/internal/gen"
)

func main() {
	var pairs [][2]rune
	for r := rune(0); r <= unicode.MaxRune; r++ {
		if f := unicode.SimpleFold(r); f != r {
			pairs = append(pairs, [2]rune{r, f})
		}
	}
	if len(pairs) == 0 {
		gen.Fatalf("no fold pairs")
	}
	fmt.Fprintf(os.Stderr, "count=%d minFold=%#x maxFold=%#x\n", len(pairs), pairs[0][0], pairs[len(pairs)-1][0])

	f := gen.Stdout()
	fmt.Fprintln(f, "// Code generated from Go unicode.SimpleFold; DO NOT EDIT.")
	fmt.Fprintln(f, "// Each entry maps a code point to the next code point in its case-fold orbit,")
	fmt.Fprintln(f, "// exactly replicating Go's unicode.SimpleFold for all of Unicode.")
	fmt.Fprintln(f, "pub const FoldPair = struct { from: u21, to: u21 };")
	fmt.Fprintf(f, "pub const fold_pairs = [_]FoldPair{\n")
	for _, p := range pairs {
		fmt.Fprintf(f, "    .{ .from = 0x%X, .to = 0x%X },\n", p[0], p[1])
	}
	fmt.Fprintln(f, "};")
	fmt.Fprintln(f)
	fmt.Fprintf(f, "pub const min_fold: u21 = 0x%X;\n", pairs[0][0])
	fmt.Fprintf(f, "pub const max_fold: u21 = 0x%X;\n", pairs[len(pairs)-1][0])
	f.Close()
}
