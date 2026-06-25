package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"strings"
)

type Case struct {
	Name string `json:"name"`
	P    string `json:"p"`
	Op   string `json:"op"`  // match | find | findall | submatch
	In   string `json:"in"`  // "corpus" | "aaa"  (reference, not the bytes)
	Lit  string `json:"lit"` // inline literal input (when non-empty)
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
	r := rand.New(rand.NewSource(20260626))
	corpus := buildCorpus(r, 256*1024)
	aaa := strings.Repeat("a", 2048)
	os.WriteFile("../src/bench_corpus.txt", []byte(corpus), 0644)
	os.WriteFile("../src/bench_aaa.txt", []byte(aaa), 0644)

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
	}
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	enc := json.NewEncoder(w)
	for _, c := range cases {
		enc.Encode(c)
	}
	fmt.Fprintf(os.Stderr, "corpus=%d bytes, aaa=%d, %d cases\n", len(corpus), len(aaa), len(cases))
}
