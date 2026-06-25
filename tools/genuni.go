package main

import (
	"fmt"
	"os"
	"sort"
	"unicode"
)

// Curated set of commonly-used general categories and scripts.
var cats = []string{
	"L", "Lu", "Ll", "Lt", "Lm", "Lo",
	"M", "Mn", "Mc", "Me",
	"N", "Nd", "Nl", "No",
	"P", "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po",
	"S", "Sm", "Sc", "Sk", "So",
	"Z", "Zs", "Zl", "Zp",
	"C", "Cc", "Cf", "Co", "Cs",
}
var scripts = []string{
	"Latin", "Greek", "Cyrillic", "Han", "Hiragana", "Katakana",
	"Hangul", "Arabic", "Hebrew", "Thai", "Devanagari",
	"Armenian", "Georgian", "Common",
}

type rng struct{ lo, hi, stride uint32 }

func emit(f *os.File, varname string, t *unicode.RangeTable) int {
	var rs []rng
	for _, r := range t.R16 {
		rs = append(rs, rng{uint32(r.Lo), uint32(r.Hi), uint32(r.Stride)})
	}
	for _, r := range t.R32 {
		rs = append(rs, rng{r.Lo, r.Hi, r.Stride})
	}
	fmt.Fprintf(f, "    .{ .name = \"%s\", .ranges = &[_]URange{\n", varname)
	for _, r := range rs {
		fmt.Fprintf(f, "        .{ .lo = 0x%X, .hi = 0x%X, .stride = %d },\n", r.lo, r.hi, r.stride)
	}
	fmt.Fprintf(f, "    } },\n")
	return len(rs)
}

func main() {
	f, _ := os.Create("unicode_tables.zig")
	defer f.Close()
	fmt.Fprintln(f, "// Code generated from Go unicode.Categories / unicode.Scripts; DO NOT EDIT.")
	fmt.Fprintln(f, "// A curated subset of the most common general categories and scripts,")
	fmt.Fprintln(f, "// stored as (lo, hi, stride) ranges replicating Go's RangeTable / appendTable.")
	fmt.Fprintln(f, "pub const URange = struct { lo: u21, hi: u21, stride: u21 };")
	fmt.Fprintln(f, "pub const UnicodeClass = struct { name: []const u8, ranges: []const URange };")
	fmt.Fprintln(f, "pub const unicode_classes = [_]UnicodeClass{")
	total := 0
	names := []string{}
	for _, c := range cats {
		if t := unicode.Categories[c]; t != nil {
			total += emit(f, c, t)
			names = append(names, c)
		}
	}
	scriptNames := append([]string{}, scripts...)
	sort.Strings(scriptNames)
	for _, s := range scripts {
		if t := unicode.Scripts[s]; t != nil {
			total += emit(f, s, t)
			names = append(names, s)
		}
	}
	fmt.Fprintln(f, "};")
	fmt.Fprintf(os.Stderr, "emitted %d classes, %d ranges total\n", len(names), total)
}
