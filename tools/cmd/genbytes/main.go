// Generates src/bytes.jsonl: differential cases whose inputs and outputs are
// JSON byte arrays, so malformed UTF-8 and NULs survive the round trip. Covers
// Perl / Longest() / CompilePOSIX modes, bounded FindAll/Split limits,
// replacement templates and parser depth limits. Run via tools/regen.sh.
package main

import (
	"bufio"
	"encoding/json"
	"math/rand"
	"os"
	"regexp"
	"strings"
)

type Case struct {
	P     string  `json:"p"`
	I     []int   `json:"i"`
	Mode  string  `json:"mode"`
	N     int     `json:"n"`
	T     string  `json:"t"`
	Err   bool    `json:"err"`
	M     []int   `json:"m"`
	All   [][]int `json:"all"`
	Repl  []int   `json:"repl"`
	Split [][]int `json:"split"`
}

func bytesOf(s string) []int {
	out := make([]int, len(s))
	for i := 0; i < len(s); i++ {
		out[i] = int(s[i])
	}
	return out
}
func main() {
	patterns := []string{"", "a", "日", "�", "(a){0}", "(?P<x>a)|(?P<x>b)", "(?P<x>a)?(?P<y>b)*", "a*", "a*?", "(a?)*", "(a*)*", "(a|ab)", "(ab|a)", "^", "$", `\b`, `\B`, `\b(?i:a)`, `a\b`, `(?i)k`, `(?i)s`, `(?i)Σ`, `\p{L}`, `[^a]`, "(?s).", "[a-z]+", `\A(a|b)+\z`, `\A(a?)*\z`, `\A(a*)*\z`, `\x{D800}`, "[", `\x`, "a**", `(?P<x>a)`, "a" + strings.Repeat("*", 999), "a" + strings.Repeat("*", 1000), strings.Repeat("(?:", 1001) + "a" + strings.Repeat(")", 1001)}
	atoms := []string{"a", "b", ".", "[ab]", "[^a]", "日", "�", `\d`, `\b`, "(a?)", "(a|ab)", "()"}
	quants := []string{"", "*", "+", "?", "{0,2}", "*?"}
	random := rand.New(rand.NewSource(20260915))
	for k := 0; k < 300; k++ {
		p := atoms[random.Intn(len(atoms))] + quants[random.Intn(len(quants))] + "|" + atoms[random.Intn(len(atoms))] + quants[random.Intn(len(quants))]
		if k%3 == 0 {
			p = `\A(` + p + `)\z`
		}
		patterns = append(patterns, p)
	}
	inputs := []string{"", "a", "ab", "baab", "a\nb", "aa bb", "日a", "KſΣσ", "\xff", "\xffa\x80b", "\xe6\x97", "�\x00a"}
	templates := []string{"[$0/$1]", "${x}/${y}", "$$:$01:$1x:${1}", "${", "$", "plain"}
	limits := []int{-1, 0, 1, 2, 5}
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	enc := json.NewEncoder(w)
	for _, p := range patterns {
		for _, mode := range []string{"perl", "longest", "posix"} {
			var re *regexp.Regexp
			var err error
			if mode == "posix" {
				re, err = regexp.CompilePOSIX(p)
			} else {
				re, err = regexp.Compile(p)
				if err == nil && mode == "longest" {
					re.Longest()
				}
			}
			for j, input := range inputs {
				c := Case{P: p, I: bytesOf(input), Mode: mode, N: limits[j%len(limits)], T: templates[j%len(templates)], Err: err != nil}
				if err == nil {
					c.M = re.FindStringSubmatchIndex(input)
					c.All = re.FindAllStringSubmatchIndex(input, c.N)
					c.Repl = bytesOf(re.ReplaceAllString(input, c.T))
					parts := re.Split(input, c.N)
					if parts != nil {
						c.Split = make([][]int, len(parts))
						for k, s := range parts {
							c.Split[k] = bytesOf(s)
						}
					}
				}
				if err := enc.Encode(c); err != nil {
					panic(err)
				}
			}
		}
	}
}
