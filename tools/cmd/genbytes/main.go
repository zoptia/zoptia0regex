// Command genbytes generates test/data/bytes.jsonl: byte-level differential
// cases whose inputs carry malformed UTF-8 and NULs, run in Perl,
// Longest() and CompilePOSIX modes with bounded FindAll/Split limits and
// replacement templates, plus parser depth limits and literal prefixes of
// surrogate code points. Run via tools/regen.sh.
package main

import (
	"math/rand"
	"strings"

	"zoptia0regex/tools/internal/corpus"
)

var fixedPatterns = []string{"", "a", "日", "�", "(a){0}", "(?P<x>a)|(?P<x>b)", "(?P<x>a)?(?P<y>b)*", "a*", "a*?", "(a?)*", "(a*)*", "(a|ab)", "(ab|a)", "^", "$", `\b`, `\B`, `\b(?i:a)`, `a\b`, `(?i)k`, `(?i)s`, `(?i)Σ`, `\p{L}`, `[^a]`, "(?s).", "[a-z]+", `\A(a|b)+\z`, `\A(a?)*\z`, `\A(a*)*\z`, `\x{D800}`, "[", `\x`, "a**", `(?P<x>a)`, "a" + strings.Repeat("*", 999), "a" + strings.Repeat("*", 1000), strings.Repeat("(?:", 1001) + "a" + strings.Repeat(")", 1001)}

var atoms = []string{"a", "b", ".", "[ab]", "[^a]", "日", "�", `\d`, `\b`, "(a?)", "(a|ab)", "()"}
var quants = []string{"", "*", "+", "?", "{0,2}", "*?"}

var inputs = []string{"", "a", "ab", "baab", "a\nb", "aa bb", "日a", "KſΣσ", "\xff", "\xffa\x80b", "\xe6\x97", "�\x00a"}
var templates = []string{"[$0/$1]", "${x}/${y}", "$$:$01:$1x:${1}", "${", "$", "plain"}
var limits = []int{-1, 0, 1, 2, 5}

// surrogate is an encoded UTF-16 surrogate (U+D800): three bytes Go
// decodes as three U+FFFD of width 1.
const surrogate = "\xed\xa0\x80"

// surrogateCases pin how a surrogate code point in a pattern behaves: it can
// never match a decoded rune, but Go's literal prefix (built with
// strings.Builder.WriteRune) holds it as U+FFFD, so prefix scans and the
// one-pass prefix skip do match "�" input bytes.
var surrogateCases = []struct {
	p      string
	inputs []string
}{
	{`^a\x{D800}`, []string{"a�", "a�b", "a" + surrogate}},
	{`^a\x{D800}$`, []string{"a�", "a�b"}},
	{`\A\x{DFFF}x\z`, []string{"�x"}},
	{`^a\x{D800}(b)`, []string{"a�b"}},
	{`^(a)\x{D800}`, []string{"a�"}},
	{`\x{D800}`, []string{"�", surrogate}},
	{`(?:\x{D800})`, []string{"�"}},
	{`[\x{D800}]`, []string{"�"}},
	{`a\x{D800}b`, []string{"a�b"}},
	{`a\x{D800}`, []string{"xa�"}},
	{`\x{D800}|\x{FFFD}`, []string{"a�", surrogate}},
	{`^a\x{D800}|b`, []string{"a�b"}},
}

func main() {
	patterns := append([]string(nil), fixedPatterns...)
	random := rand.New(rand.NewSource(20260915))
	for k := 0; k < 300; k++ {
		p := atoms[random.Intn(len(atoms))] + quants[random.Intn(len(quants))] + "|" + atoms[random.Intn(len(atoms))] + quants[random.Intn(len(quants))]
		if k%3 == 0 {
			p = `\A(` + p + `)\z`
		}
		patterns = append(patterns, p)
	}
	w := corpus.NewWriter()
	for _, p := range patterns {
		for _, mode := range corpus.Modes {
			c := corpus.Compile(p, mode)
			if c.Err != "" {
				w.Write(c.Case(""))
				continue
			}
			for j, input := range inputs {
				w.Write(c.CaseAll(input, limits[j%len(limits)], templates[j%len(templates)]))
			}
		}
	}
	for _, sc := range surrogateCases {
		for _, mode := range corpus.Modes {
			c := corpus.Compile(sc.p, mode)
			if c.Err != "" {
				w.Write(c.Case(""))
				continue
			}
			for _, input := range sc.inputs {
				w.Write(c.CaseAll(input, -1, "[$0/$1]"))
			}
		}
	}
	w.Close()
}
