package main

// Generates src/unicode_tables.zig from the Go toolchain's unicode package:
// every general category and script table (the full set Go's regexp accepts),
// the case-fold companion tables (unicode.FoldCategory / unicode.FoldScript)
// that regexp/syntax merges under (?i), and unicode.CategoryAliases. Names are
// emitted alongside their canonical form (see canonicalName below, a copy of
// regexp/syntax's) so lookups can ignore case, '_', '-' and spaces exactly
// like Go 1.27's unicodeTable.

import (
	"fmt"
	"os"
	"sort"
	"unicode"
)

type rng struct{ lo, hi, stride uint32 }

func ranges(t *unicode.RangeTable) []rng {
	var rs []rng
	for _, r := range t.R16 {
		rs = append(rs, rng{uint32(r.Lo), uint32(r.Hi), uint32(r.Stride)})
	}
	for _, r := range t.R32 {
		rs = append(rs, rng{r.Lo, r.Hi, r.Stride})
	}
	return rs
}

// canonicalName mirrors regexp/syntax.canonicalName: leading letter
// uppercased, the rest lowercased, '_', '-' and ' ' dropped.
func canonicalName(name string) string {
	b := make([]byte, 0, len(name))
	first := true
	for i := 0; i < len(name); i++ {
		c := name[i]
		switch {
		case c == '_' || c == '-' || c == ' ':
			continue
		case first:
			if 'a' <= c && c <= 'z' {
				c -= 'a' - 'A'
			}
			first = false
		default:
			if 'A' <= c && c <= 'Z' {
				c += 'a' - 'A'
			}
		}
		b = append(b, c)
	}
	return string(b)
}

func sortedKeys[T any](m map[string]T) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}

func emitRanges(f *os.File, indent string, rs []rng) {
	fmt.Fprintf(f, "&[_]URange{\n")
	for _, r := range rs {
		fmt.Fprintf(f, "%s    .{ .lo = 0x%X, .hi = 0x%X, .stride = %d },\n", indent, r.lo, r.hi, r.stride)
	}
	fmt.Fprintf(f, "%s}", indent)
}

func emitClasses(f *os.File, varname string, tables map[string]*unicode.RangeTable, folds map[string]*unicode.RangeTable) int {
	total := 0
	fmt.Fprintf(f, "pub const %s = [_]UnicodeClass{\n", varname)
	for _, name := range sortedKeys(tables) {
		rs := ranges(tables[name])
		total += len(rs)
		fmt.Fprintf(f, "    .{ .name = \"%s\", .canon = \"%s\", .ranges = ", name, canonicalName(name))
		emitRanges(f, "    ", rs)
		if ft := folds[name]; ft != nil {
			frs := ranges(ft)
			total += len(frs)
			fmt.Fprintf(f, ", .fold = ")
			emitRanges(f, "    ", frs)
		}
		fmt.Fprintln(f, " },")
	}
	fmt.Fprintln(f, "};")
	return total
}

func main() {
	f, err := os.Create("unicode_tables.zig")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer f.Close()
	fmt.Fprintln(f, "// Code generated from Go's unicode package; DO NOT EDIT.")
	fmt.Fprintf(f, "// Unicode %s: every general category and script table Go's regexp accepts,\n", unicode.Version)
	fmt.Fprintln(f, "// stored as (lo, hi, stride) ranges replicating Go's RangeTable / appendTable.")
	fmt.Fprintln(f, "// `fold` (unicode.FoldCategory / unicode.FoldScript) holds the code points")
	fmt.Fprintln(f, "// outside the class that case-fold into it; regexp/syntax merges it under (?i).")
	fmt.Fprintln(f, "// `canon` is the name passed through regexp/syntax's canonicalName.")
	fmt.Fprintf(f, "pub const unicode_version = \"%s\";\n", unicode.Version)
	fmt.Fprintln(f, "pub const URange = struct { lo: u21, hi: u21, stride: u21 };")
	fmt.Fprintln(f, "pub const UnicodeClass = struct { name: []const u8, canon: []const u8, ranges: []const URange, fold: ?[]const URange = null };")
	fmt.Fprintln(f, "pub const Alias = struct { canon: []const u8, actual: []const u8 };")
	fmt.Fprintln(f)
	total := emitClasses(f, "categories", unicode.Categories, unicode.FoldCategory)
	fmt.Fprintln(f)
	total += emitClasses(f, "scripts", unicode.Scripts, unicode.FoldScript)
	fmt.Fprintln(f)
	fmt.Fprintln(f, "/// unicode.CategoryAliases keyed by canonical alias name.")
	fmt.Fprintln(f, "pub const category_aliases = [_]Alias{")
	for _, name := range sortedKeys(unicode.CategoryAliases) {
		fmt.Fprintf(f, "    .{ .canon = \"%s\", .actual = \"%s\" },\n", canonicalName(name), unicode.CategoryAliases[name])
	}
	fmt.Fprintln(f, "};")
	fmt.Fprintf(os.Stderr, "unicode %s: %d categories, %d scripts, %d aliases, %d ranges total\n",
		unicode.Version, len(unicode.Categories), len(unicode.Scripts), len(unicode.CategoryAliases), total)
}
