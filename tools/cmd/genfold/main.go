package main

import (
	"fmt"
	"os"
	"unicode"
)

func main() {
	// Dump (from -> SimpleFold(from)) for every rune whose simple fold differs.
	var pairs [][2]rune
	for r := rune(0); r <= unicode.MaxRune; r++ {
		f := unicode.SimpleFold(r)
		if f != r {
			pairs = append(pairs, [2]rune{r, f})
		}
	}
	fmt.Fprintf(os.Stderr, "count=%d minFold=%#x maxFold=%#x\n", len(pairs), pairs[0][0], pairs[len(pairs)-1][0])
	// Emit a Zig source file.
	f, _ := os.Create("fold_table.zig")
	defer f.Close()
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
}
