// Command genlongest generates test/data/longest.jsonl, the randomized
// leftmost-longest differential corpus. Run via tools/regen.sh.
//
// Streams, each with its own seed:
//
//	longest  Perl-syntax patterns compiled with regexp.Compile and switched
//	         to Longest(), isolating leftmost-longest semantics from POSIX
//	         syntax
//	posix    POSIX ERE patterns compiled with regexp.CompilePOSIX (POSIX
//	         syntax: line-anchored ^ and $, stacked repetition, no Perl
//	         classes), on inputs that may hold NULs and malformed UTF-8
//
// Patterns that fail to compile are recorded as error cases. Every case
// also records the find-all family (unlimited, template "[$0/$1]").
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
	mode    corpus.Mode
	pattern func(*rand.Rand) string
	input   func(*rand.Rand) string
}

var streams = []stream{
	{424242, 2500, corpus.Longest, randre.Longest, randre.LongestInput},
	{20261119, 800, corpus.POSIX, randre.POSIX, randre.ByteInput},
}

func main() {
	w := corpus.NewWriter()
	for _, s := range streams {
		r := rand.New(rand.NewSource(s.seed))
		for k := 0; k < s.count; k++ {
			c := corpus.Compile(s.pattern(r), s.mode)
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
