// Package randre holds the grammar-driven random pattern and input
// generators of the randomized corpora. Each generator takes its own
// *rand.Rand so every stream is reproducible on its own; the call order of
// the original streams (Perl, Alternation, Longest and their inputs) must
// not change, or the committed corpora would churn for no reason.
package randre

import (
	"math/rand"
	"strings"
)

var atoms = []string{"a", "b", "c", "x", " ", "1", "2", "Z", ".", "\\d", "\\w", "\\s", "\\.", "\\*", "[abc]", "[a-c]", "[^a-c]", "[0-9]", "[[:alpha:]]", "\\pL", "\\p{Nd}"}
var quants = []string{"", "", "*", "+", "?", "*?", "+?", "??", "{2}", "{1,3}", "{0,2}", "{2,}"}
var anchors = []string{"^", "$", "\\b", "\\B", "\\A", "\\z"}
var flags = []string{"", "", "", "(?i)", "(?s)", "(?m)", "(?i)", "(?is)"}

func genAtom(r *rand.Rand, depth int) string {
	if depth > 0 && r.Intn(3) == 0 {
		inner := genConcat(r, depth-1)
		switch r.Intn(3) {
		case 0:
			return "(" + inner + ")"
		default:
			return "(?:" + inner + ")"
		}
	}
	return atoms[r.Intn(len(atoms))]
}

func genPiece(r *rand.Rand, depth int) string {
	a := genAtom(r, depth)
	return a + quants[r.Intn(len(quants))]
}

func genConcat(r *rand.Rand, depth int) string {
	n := 1 + r.Intn(3)
	s := ""
	for i := 0; i < n; i++ {
		if r.Intn(6) == 0 {
			s += anchors[r.Intn(len(anchors))]
		}
		s += genPiece(r, depth)
	}
	if r.Intn(4) == 0 && depth > 0 {
		s += "|" + genConcat(r, depth-1)
	}
	return s
}

// Perl returns a random Perl-syntax pattern: flags, groups, classes, Perl
// and Unicode classes, greedy and lazy quantifiers, anchors, alternation.
func Perl(r *rand.Rand) string {
	f := flags[r.Intn(len(flags))]
	return f + genConcat(r, 3)
}

// altStems and altTails build alternations whose branches share prefixes,
// the input shape Go's parser factors (literal prefixes, leading classes,
// fixed repeats, single runes merged into classes).
var altStems = []string{"ab", "abc", "a", "b", "ba", "x", "xa", "[ab]", "[ab]{2}", "\\d", "\\d\\d", ".", "(a)", "(?:ab)", "(?i:ab)", "a*", "a+?", ""}
var altTails = []string{"", "a", "b", "c", "x", "ab", "bc", "\\d", "[xy]", "a?", "(b)", "$", "\\b"}

// Alternation returns a random alternation with shared branch prefixes.
func Alternation(r *rand.Rand) string {
	n := 2 + r.Intn(7)
	parts := make([]string, n)
	for i := range parts {
		parts[i] = altStems[r.Intn(len(altStems))] + altTails[r.Intn(len(altTails))]
		if r.Intn(4) == 0 {
			parts[i] += altTails[r.Intn(len(altTails))]
		}
	}
	s := strings.Join(parts, "|")
	switch r.Intn(5) {
	case 0:
		s = "(" + s + ")"
	case 1:
		s = "(?:" + s + ")+"
	case 2:
		s = `\A(?:` + s + `)\z`
	}
	return flags[r.Intn(len(flags))] + s
}

func runesOf(r *rand.Rand, alphabet []rune, maxLen int) string {
	n := r.Intn(maxLen)
	rs := make([]rune, n)
	for i := range rs {
		rs[i] = alphabet[r.Intn(len(alphabet))]
	}
	return string(rs)
}

var perlInput = []rune("abcxZ12 .\n\tαβΑΒ日")
var altInput = []rune("abcxy12 AB\nΑ")

// PerlInput returns a random valid-UTF-8 input for Perl patterns.
func PerlInput(r *rand.Rand) string { return runesOf(r, perlInput, 12) }

// AltInput returns a random valid-UTF-8 input for Alternation patterns.
func AltInput(r *rand.Rand) string { return runesOf(r, altInput, 10) }

var latoms = []string{"a", "b", "c", "x", " ", "1", "2", "Z", ".", "\\d", "\\w", "\\s", "[abc]", "[a-c]", "[^a-c]", "[0-9]"}
var lquants = []string{"", "", "*", "+", "?", "{2}", "{1,3}", "{0,2}", "{2,}"}
var lanchors = []string{"^", "$", "\\b"}

func lgenAtom(r *rand.Rand, depth int) string {
	if depth > 0 && r.Intn(3) == 0 {
		inner := lgenConcat(r, depth-1)
		if r.Intn(2) == 0 {
			return "(" + inner + ")"
		}
		return "(?:" + inner + ")"
	}
	return latoms[r.Intn(len(latoms))]
}

func lgenPiece(r *rand.Rand, depth int) string {
	return lgenAtom(r, depth) + lquants[r.Intn(len(lquants))]
}

func lgenConcat(r *rand.Rand, depth int) string {
	n := 1 + r.Intn(3)
	s := ""
	for i := 0; i < n; i++ {
		if r.Intn(7) == 0 {
			s += lanchors[r.Intn(len(lanchors))]
		}
		s += lgenPiece(r, depth)
	}
	if r.Intn(3) == 0 && depth > 0 {
		s += "|" + lgenConcat(r, depth-1)
	}
	return s
}

// Longest returns a random Perl-syntax pattern for leftmost-longest runs
// (greedy quantifiers only; laziness is meaningless there).
func Longest(r *rand.Rand) string { return lgenConcat(r, 3) }

var longestInput = []rune("abcxZ12 αβ")

// LongestInput returns a random valid-UTF-8 input for Longest patterns.
func LongestInput(r *rand.Rand) string { return runesOf(r, longestInput, 10) }

// POSIX ERE atoms: no Perl classes, no non-capturing groups, no \b, \A,
// \z or \pN.
var patoms = []string{"a", "b", "c", "x", " ", "1", "Z", ".", "\\.", "\\*", "\\$", "[abc]", "[a-c]", "[^a-c]", "[^\\n]", "[[:alpha:]]", "[[:digit:]]", "[[:space:]]", "[[:^alpha:]]", "日"}

// perlOnly are Perl-syntax tokens CompilePOSIX rejects; POSIX appends one
// to a few patterns so the stream also records those errors.
var perlOnly = []string{"\\d", "(?:a)", "\\b", "\\pL", "\\A", "\\z"}

// POSIX allows stacked repetition operators (a** is (a*)*); there are no
// lazy quantifiers, so "*?" is "(a*)?".
var pquants = []string{"", "", "", "*", "+", "?", "{2}", "{1,3}", "{0,2}", "{2,}", "*?", "+*", "??", "{1}*"}
var panchors = []string{"^", "$"}

func pgenAtom(r *rand.Rand, depth int) string {
	if depth > 0 && r.Intn(3) == 0 {
		return "(" + pgenConcat(r, depth-1) + ")"
	}
	return patoms[r.Intn(len(patoms))]
}

func pgenConcat(r *rand.Rand, depth int) string {
	n := 1 + r.Intn(3)
	s := ""
	for i := 0; i < n; i++ {
		if r.Intn(6) == 0 {
			s += panchors[r.Intn(len(panchors))]
		}
		s += pgenAtom(r, depth) + pquants[r.Intn(len(pquants))]
	}
	if r.Intn(3) == 0 && depth > 0 {
		s += "|" + pgenConcat(r, depth-1)
	}
	return s
}

// POSIX returns a random POSIX ERE pattern for regexp.CompilePOSIX.
func POSIX(r *rand.Rand) string {
	p := pgenConcat(r, 3)
	if r.Intn(16) == 0 {
		p += perlOnly[r.Intn(len(perlOnly))]
	}
	return p
}

// byteTokens mixes ASCII, multi-byte runes, NUL and malformed UTF-8:
// stray continuation bytes, truncated sequences, an encoded surrogate,
// an overlong encoding and a code point above U+10FFFF.
var byteTokens = []string{"a", "b", "c", "x", "1", " ", "\n", "日", "α", "�", "\x00", "\xff", "\x80", "\xe6\x97", "\xed\xa0\x80", "\xc0\x80", "\xf4\x90\x80\x80"}

// ByteInput returns a random input that may contain NULs and malformed UTF-8.
func ByteInput(r *rand.Rand) string {
	n := r.Intn(10)
	var b strings.Builder
	for i := 0; i < n; i++ {
		b.WriteString(byteTokens[r.Intn(len(byteTokens))])
	}
	return b.String()
}

// breakers are splices that usually make a pattern invalid, one per
// syntax.ErrorCode class the parser can report (plus a few that are valid
// in context, which is fine: the outcome is recorded either way).
var breakers = []string{"(", ")", "[", "]", "[a", "\\", "*", "+", "?", "**", "{2,1}", "{1001}", "\\x", "\\x{110000}", "\\8", "(?P<", "(?P<1a>x)", "(?P<n>", "(?z)", "(?i", "(?<", "\\p{Foo}", "\\pX", "[z-a]", "[[:foo:]]", "\xff", "\xe6\x97", "\\Q", "\\C", "x{2}{3}*", "a**"}

// Invalid splices a breaker into a random Perl pattern at a random byte
// offset (Perl patterns are ASCII, so every offset is a rune boundary; the
// malformed-UTF-8 breakers make the pattern itself invalid UTF-8).
func Invalid(r *rand.Rand) string {
	p := Perl(r)
	at := r.Intn(len(p) + 1)
	return p[:at] + breakers[r.Intn(len(breakers))] + p[at:]
}
