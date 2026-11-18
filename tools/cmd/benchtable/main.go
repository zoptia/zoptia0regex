// Command benchtable turns the benchmark harnesses' TSV output into the
// Markdown blocks embedded in BENCHMARKS.md and README.md, so no benchmark
// number in the docs is ever typed by hand. tools/bench.sh runs it:
//
//	benchtable -go go.tsv -zig zig.tsv -goscratch gos.tsv -zigscratch zigs.tsv \
//	    -cpu "Apple M4" -update BENCHMARKS.md -update README.md
//
// Each document holds generated blocks between markers
//
//	<!-- BEGIN GENERATED: NAME -->
//	<!-- END GENERATED: NAME -->
//
// and -update rewrites every block it knows (bench-env, bench-results,
// bench-headline, scratch-results) that the file contains. A file passed
// to -update must contain at least one block. It also checks that both
// sides computed the same result for every case (the harnesses record the
// value of one single run of each operation), and aborts otherwise.
package main

import (
	"bufio"
	"bytes"
	"flag"
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"

	"zoptia0regex/tools/internal/gen"
)

// table is a parsed TSV: "# key=value ..." meta lines, a header, rows.
type table struct {
	meta map[string]string
	cols map[string]int
	rows [][]string
}

func readTSV(path string) *table {
	t := &table{meta: map[string]string{}, cols: map[string]int{}}
	sc := bufio.NewScanner(bytes.NewReader(gen.ReadFile(path)))
	for sc.Scan() {
		line := sc.Text()
		switch {
		case line == "":
		case strings.HasPrefix(line, "#"):
			for _, kv := range strings.Fields(strings.TrimPrefix(line, "#")) {
				k, v, ok := strings.Cut(kv, "=")
				if !ok {
					gen.Fatalf("%s: bad meta field %q", path, kv)
				}
				t.meta[k] = v
			}
		case len(t.cols) == 0:
			for i, c := range strings.Split(line, "\t") {
				t.cols[c] = i
			}
		default:
			row := strings.Split(line, "\t")
			if len(row) != len(t.cols) {
				gen.Fatalf("%s: row %q has %d fields, header has %d", path, line, len(row), len(t.cols))
			}
			t.rows = append(t.rows, row)
		}
	}
	gen.Check(sc.Err())
	if len(t.rows) == 0 {
		gen.Fatalf("%s: no rows", path)
	}
	return t
}

func (t *table) get(row []string, col string) string {
	i, ok := t.cols[col]
	if !ok {
		gen.Fatalf("missing column %q", col)
	}
	return row[i]
}

func (t *table) num(row []string, col string) float64 {
	v, err := strconv.ParseFloat(t.get(row, col), 64)
	gen.Check(err)
	if v <= 0 {
		gen.Fatalf("non-positive %s %v", col, v)
	}
	return v
}

// sameCases checks that both tables list the same case names in the same
// order with the same single-run result.
func sameCases(a, b *table, what string) {
	if len(a.rows) != len(b.rows) {
		gen.Fatalf("%s: %d Go rows vs %d Zig rows", what, len(a.rows), len(b.rows))
	}
	for i := range a.rows {
		na, nb := a.get(a.rows[i], "name"), b.get(b.rows[i], "name")
		if na != nb {
			gen.Fatalf("%s: row %d is %q on Go, %q on Zig", what, i, na, nb)
		}
		ra, rb := a.get(a.rows[i], "result"), b.get(b.rows[i], "result")
		if ra != rb {
			gen.Fatalf("%s: %s: Go result %s, Zig result %s", what, na, ra, rb)
		}
	}
}

func geomean(xs []float64) float64 {
	s := 0.0
	for _, x := range xs {
		s += math.Log(x)
	}
	return math.Exp(s / float64(len(xs)))
}

// ns formats nanoseconds with thousands separators.
func ns(v float64) string {
	s := strconv.FormatInt(int64(math.Round(v)), 10)
	var b strings.Builder
	for i, c := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(c)
	}
	return b.String()
}

// ratio formats a Zig/Go ratio, bold when Zig is faster.
func ratio(r float64) string {
	s := fmt.Sprintf("%.2f×", r)
	if r < 1 {
		return "**" + s + "**"
	}
	return s
}

type results struct {
	blocks map[string]string
}

func build(goT, zigT, goS, zigS *table, cpu string) results {
	sameCases(goT, zigT, "bench")
	sameCases(goS, zigS, "scratch")

	var b strings.Builder
	fmt.Fprintln(&b, "| case | op | engine (port) | Go ns/op | Zig ns/op | Zig/Go |")
	fmt.Fprintln(&b, "|------|----|---------------|---------:|----------:|-------:|")
	var all, nonLiteral, compile []float64
	for i, gr := range goT.rows {
		zr := zigT.rows[i]
		g, z := goT.num(gr, "op_ns"), zigT.num(zr, "op_ns")
		r := z / g
		engine := zigT.get(zr, "engine")
		all = append(all, r)
		if engine != "literal" {
			nonLiteral = append(nonLiteral, r)
		}
		compile = append(compile, zigT.num(zr, "compile_ns")/goT.num(gr, "compile_ns"))
		fmt.Fprintf(&b, "| %s | %s | %s | %s | %s | %s |\n", goT.get(gr, "name"), goT.get(gr, "op"), engine, ns(g), ns(z), ratio(r))
	}
	gAll, gNon, gComp := geomean(all), geomean(nonLiteral), geomean(compile)
	fmt.Fprintf(&b, "| **geomean (%d cases)** | | | | | %s |\n", len(all), ratio(gAll))
	fmt.Fprintf(&b, "| geomean without literal fast-path rows (%d cases) | | | | | %s |\n", len(nonLiteral), ratio(gNon))
	fmt.Fprintf(&b, "| **compile geomean** | | | | | %s |\n", ratio(gComp))
	resultsBlock := b.String()

	headline := fmt.Sprintf("Across %d workloads the port's geometric-mean time is **%.2f×** Go's "+
		"(%.2f× without the literal fast-path rows), and it compiles patterns in **%.2f×** Go's time.\n",
		len(all), gAll, gNon, gComp)

	b.Reset()
	fmt.Fprintln(&b, "| case | engine (port) | Go `MatchString` ns | Zig `match` (alloc) ns | Zig `matchScratch` ns | scratch/Go |")
	fmt.Fprintln(&b, "|------|---------------|-------------------:|----------------------:|---------------------:|-----------:|")
	var sr []float64
	for i, gr := range goS.rows {
		zr := zigS.rows[i]
		g, s := goS.num(gr, "go_ns"), zigS.num(zr, "scratch_ns")
		sr = append(sr, s/g)
		fmt.Fprintf(&b, "| %s | %s | %s | %s | %s | %s |\n", goS.get(gr, "name"), zigS.get(zr, "engine"), ns(g), ns(zigS.num(zr, "alloc_ns")), ns(s), ratio(s/g))
	}
	fmt.Fprintf(&b, "| **geomean** | | | | | %s |\n", ratio(geomean(sr)))
	scratchBlock := b.String()

	b.Reset()
	fmt.Fprintln(&b, "| | |")
	fmt.Fprintln(&b, "|---|---|")
	if cpu != "" {
		fmt.Fprintf(&b, "| CPU | %s |\n", cpu)
	}
	fmt.Fprintf(&b, "| Go | %s (%s/%s) |\n", goT.meta["go"], goT.meta["os"], goT.meta["arch"])
	fmt.Fprintf(&b, "| Zig | %s, %s, `-OReleaseFast` |\n", zigT.meta["zig"], zigT.meta["target"])
	envBlock := b.String()

	return results{blocks: map[string]string{
		"bench-env":       envBlock,
		"bench-results":   resultsBlock,
		"bench-headline":  headline,
		"scratch-results": scratchBlock,
	}}
}

// update rewrites every known generated block in path.
func update(path string, res results) {
	doc := string(gen.ReadFile(path))
	found := 0
	for name, body := range res.blocks {
		begin := "<!-- BEGIN GENERATED: " + name + " -->\n"
		end := "<!-- END GENERATED: " + name + " -->"
		i := strings.Index(doc, begin)
		if i < 0 {
			continue
		}
		j := strings.Index(doc[i:], end)
		if j < 0 {
			gen.Fatalf("%s: block %s has no end marker", path, name)
		}
		doc = doc[:i+len(begin)] + body + doc[i+j:]
		found++
	}
	if found == 0 {
		gen.Fatalf("%s: no generated blocks", path)
	}
	gen.WriteFile(path, []byte(doc))
	fmt.Fprintf(os.Stderr, "%s: updated %d blocks\n", path, found)
}

type multi []string

func (m *multi) String() string     { return strings.Join(*m, ",") }
func (m *multi) Set(v string) error { *m = append(*m, v); return nil }

func main() {
	goTSV := flag.String("go", "", "benchgo output")
	zigTSV := flag.String("zig", "", "zig build bench output")
	goScratch := flag.String("goscratch", "", "benchscratchgo output")
	zigScratch := flag.String("zigscratch", "", "zig build bench-scratch output")
	cpu := flag.String("cpu", "", "CPU description for the environment table")
	var files multi
	flag.Var(&files, "update", "document to update in place (repeatable); without it, print the blocks")
	flag.Parse()
	if *goTSV == "" || *zigTSV == "" || *goScratch == "" || *zigScratch == "" || flag.NArg() != 0 {
		gen.Fatalf("usage: benchtable -go F -zig F -goscratch F -zigscratch F [-cpu S] [-update DOC]...")
	}
	res := build(readTSV(*goTSV), readTSV(*zigTSV), readTSV(*goScratch), readTSV(*zigScratch), *cpu)
	if len(files) == 0 {
		out := gen.Stdout()
		for _, name := range []string{"bench-env", "bench-headline", "bench-results", "scratch-results"} {
			fmt.Fprintf(out, "## %s\n\n%s\n", name, res.blocks[name])
		}
		out.Close()
		return
	}
	for _, f := range files {
		update(f, res)
	}
}
