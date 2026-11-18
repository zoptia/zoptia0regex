// Command genbench writes the benchmark workloads shared by the Zig and Go
// harnesses into a directory (bench/data via tools/regen.sh):
//
//	bench.jsonl        throughput cases (bench/bench.zig, cmd/benchgo)
//	bench_corpus.txt   256 KB deterministic mixed-text corpus
//	bench_aaa.txt      2 KB of 'a' for the nested-quantifier case
//	scratch.jsonl      short-input cases of the Scratch micro-benchmark
//	                   (bench/bench_scratch.zig, cmd/benchscratchgo)
//
// Usage: genbench -dir bench/data
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"strings"

	"zoptia0regex/tools/internal/gen"
)

// Case is one throughput case.
type Case struct {
	Name string `json:"name"`
	P    string `json:"p"`
	Op   string `json:"op"`  // match | find | findall | submatch
	In   string `json:"in"`  // "corpus" | "aaa"  (reference, not the bytes)
	Lit  string `json:"lit"` // inline literal input (when non-empty)
}

// ScratchCase is one Scratch micro-benchmark case (op is always match).
type ScratchCase struct {
	Name string `json:"name"`
	P    string `json:"p"`
	In   string `json:"in"`
}

// scratchCases are short inputs where per-call setup dominates. Each row
// runs an engine except "literal", which the port answers with its
// literal fast path (no engine, no allocation).
var scratchCases = []ScratchCase{
	{"literal", "needle", "a haystack with a needle hidden somewhere near the end"},
	{"prefix_digits", `needle\d+`, "a haystack with a needle42 hidden somewhere near the end"},
	{"alternation", "(foo|bar|baz)+", "zz bar foo baz qux barbaz zz"},
	{"email_unanchored", `[a-z]+@[a-z]+\.[a-z]+`, "please contact us at user@example.com today"},
	{"charclass_plus", "[0-9]+", "order 12345 shipped on 2024"},
	{"anchored_onepass", `\A\d+\z`, "1234567890"},
}

func writeJSONL[T any](path string, items []T) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	for _, it := range items {
		gen.Check(enc.Encode(it))
	}
	gen.WriteFile(path, buf.Bytes())
}

var words = strings.Fields(`the quick brown fox jumps over lazy dog lorem ipsum dolor sit amet consectetur
adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua enim ad minim veniam
quis nostrud exercitation ullamco laboris nisi aliquip ex ea commodo consequat duis aute irure reprehenderit
performance regular expression engine matching throughput latency benchmark comparison faithful`)

func buildCorpus(r *rand.Rand, targetLen int) string {
	var b strings.Builder
	for b.Len() < targetLen {
		switch r.Intn(20) {
		case 0:
			fmt.Fprintf(&b, "%d ", r.Intn(1000000))
		case 1:
			fmt.Fprintf(&b, "%04d-%02d-%02d ", 2000+r.Intn(26), 1+r.Intn(12), 1+r.Intn(28))
		case 2:
			fmt.Fprintf(&b, "%s.%s@%s.com ", words[r.Intn(len(words))], words[r.Intn(len(words))], words[r.Intn(len(words))])
		case 3:
			b.WriteString("performance ")
		case 4:
			b.WriteString("café naïve Москва 日本語 ")
		default:
			b.WriteString(words[r.Intn(len(words))])
			b.WriteByte(' ')
		}
		if r.Intn(12) == 0 {
			b.WriteByte('\n')
		}
	}
	return b.String()
}

func main() {
	dir := flag.String("dir", "", "output directory")
	flag.Parse()
	if *dir == "" || flag.NArg() != 0 {
		gen.Fatalf("usage: genbench -dir DIR")
	}
	r := rand.New(rand.NewSource(20260626))
	corpus := buildCorpus(r, 256*1024)
	aaa := strings.Repeat("a", 2048)
	gen.WriteFile(filepath.Join(*dir, "bench_corpus.txt"), []byte(corpus))
	gen.WriteFile(filepath.Join(*dir, "bench_aaa.txt"), []byte(aaa))

	cases := []Case{
		{"literal_hit", "performance", "find", "corpus", ""},
		{"literal_miss", "zzqqxxjjkk", "find", "corpus", ""},
		{"alternation", "performance|benchmark|expression|throughput", "findall", "corpus", ""},
		{"charclass_word", "[A-Za-z]+", "findall", "corpus", ""},
		{"perl_word", "\\w+", "findall", "corpus", ""},
		{"digits", "\\d+", "findall", "corpus", ""},
		{"date", "\\d{4}-\\d{2}-\\d{2}", "findall", "corpus", ""},
		{"email", "[\\w.]+@[\\w.]+\\.\\w+", "findall", "corpus", ""},
		{"email_submatch", "([\\w.]+)@([\\w.]+)\\.(\\w+)", "submatch", "corpus", ""},
		{"anchored_multiline", "(?m)^\\w+", "findall", "corpus", ""},
		{"unicode_letters", "\\p{L}+", "findall", "corpus", ""},
		{"dotstar_greedy", "p.*e", "find", "corpus", ""},
		{"redos_linear", "(a+)+$", "match", "aaa", ""},
		{"nested_groups", "(\\w+)\\s+(\\w+)\\s+(\\w+)", "findall", "corpus", ""},
		{"caseins_literal", "(?i)performance", "findall", "corpus", ""},
		// anchored "validation" patterns -> one-pass engine, short whole-string inputs
		{"anchored_caseins", "\\A(?i)performance\\z", "match", "", "performance"},
		{"anchored_word", "\\A[a-z]+\\z", "match", "", "performance"},
		{"anchored_date", "\\A\\d{4}-\\d{2}-\\d{2}\\z", "match", "", "2024-01-15"},
		{"anchored_digits", "\\A\\d+\\z", "match", "", "1234567890"},
		{"anchored_email", "\\A([\\w.]+)@(\\w+)\\.(\\w+)\\z", "submatch", "", "john.doe@example.com"},
		// Alternations with shared prefixes: what Go's factor pass targets.
		{"keyword_list", "performance|performer|perform|period|periodic|permit|permission|persist|person|personal|benchmark|bench|benefit|between|beyond|expression|express|expressive|extend|extension|external|extra|throughput|through|throw|thread|threshold|threat|compile|compiler|complete|complex|component|compose|computer|compute|concept|concern|condition|connect", "findall", "corpus", ""},
		{"domain_allowlist", "(?i)\\A(?:mail\\.example\\.com|www\\.example\\.com|api\\.example\\.com|cdn\\.example\\.com|static\\.example\\.com|login\\.example\\.com|auth\\.example\\.com|vpn\\.example\\.com|git\\.example\\.com|ci\\.example\\.com|mail\\.corp\\.net|www\\.corp\\.net|api\\.corp\\.net|wiki\\.corp\\.net|jira\\.corp\\.net|git\\.corp\\.net|vpn\\.corp\\.net|sso\\.corp\\.net|docs\\.corp\\.net|chat\\.corp\\.net)\\z", "match", "", "SSO.corp.net"},
	}
	writeJSONL(filepath.Join(*dir, "bench.jsonl"), cases)
	writeJSONL(filepath.Join(*dir, "scratch.jsonl"), scratchCases)
	fmt.Fprintf(os.Stderr, "corpus=%d bytes, aaa=%d, %d cases, %d scratch cases\n", len(corpus), len(aaa), len(cases), len(scratchCases))
}
