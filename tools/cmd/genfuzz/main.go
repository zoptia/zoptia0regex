// Command genfuzz generates test/data/fuzz.jsonl, the randomized Perl-syntax
// differential corpus. Every case records the find-all family too
// (FindAllStringSubmatchIndex, ReplaceAllString with "[$0/$1]", Split, all
// unlimited). Run via tools/regen.sh.
//
// Streams, each with its own seed so adding one never changes another:
//
//	perl        random Perl-syntax patterns on valid UTF-8 inputs
//	alternation alternations with shared prefixes (Go's factor pass)
//	bytes       random Perl-syntax patterns on inputs with NULs and
//	            malformed UTF-8
//	invalid     random patterns with a syntax error spliced in; recorded
//	            with Go's error code (or run on byte inputs when the splice
//	            happened to leave the pattern valid)
package main

import (
	"math/rand"

	"zoptia0regex/tools/internal/corpus"
	"zoptia0regex/tools/internal/randre"
)

const replT = "[$0/$1]"

const inputsPerPattern = 6

type stream struct {
	seed    int64
	count   int
	pattern func(*rand.Rand) string
	input   func(*rand.Rand) string
}

var streams = []stream{
	{20260625, 1500, randre.Perl, randre.PerlInput},
	{20260922, 300, randre.Alternation, randre.AltInput},
	{20261117, 400, randre.Perl, randre.ByteInput},
	{20261118, 400, randre.Invalid, randre.ByteInput},
}

func main() {
	w := corpus.NewWriter()
	for _, s := range streams {
		r := rand.New(rand.NewSource(s.seed))
		for k := 0; k < s.count; k++ {
			c := corpus.Compile(s.pattern(r), corpus.Perl)
			if c.Err != "" {
				w.Write(c.Case(""))
				continue
			}
			for j := 0; j < inputsPerPattern; j++ {
				w.Write(c.CaseAll(s.input(r), -1, replT))
			}
		}
	}
	w.Close()
}
