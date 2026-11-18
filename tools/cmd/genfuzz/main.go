package main

import (
	"bufio"
	"encoding/json"
	"math/rand"
	"os"
	"regexp"
	"regexp/syntax"
	"strings"
)

type Case struct {
	P     string   `json:"p"`
	I     string   `json:"i"`
	Err   bool     `json:"err"`
	M     []int    `json:"m"`
	All   [][]int  `json:"all"`
	Repl  string   `json:"repl"`
	Split []string `json:"split"`
	NI    int      `json:"ni,omitempty"` // Go's program length (see progLen)
}

// progLen is the instruction count of the program Go's regexp.Compile builds
// for p (syntax.Parse with Perl flags, Simplify, Compile). The port must
// produce the same AST shape, so its program has exactly this many
// instructions; the differential tests check it.
func progLen(p string) int {
	re, err := syntax.Parse(p, syntax.Perl)
	if err != nil {
		return 0
	}
	prog, err := syntax.Compile(re.Simplify())
	if err != nil {
		return 0
	}
	return len(prog.Inst)
}

// genAlternation builds an alternation whose branches share prefixes, the
// input shape Go's parser factors (literal prefixes, leading classes, fixed
// repeats, single runes merged into classes).
var altStems = []string{"ab", "abc", "a", "b", "ba", "x", "xa", "[ab]", "[ab]{2}", "\\d", "\\d\\d", ".", "(a)", "(?:ab)", "(?i:ab)", "a*", "a+?", ""}
var altTails = []string{"", "a", "b", "c", "x", "ab", "bc", "\\d", "[xy]", "a?", "(b)", "$", "\\b"}

func genAlternation(r *rand.Rand) string {
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

const replT = "[$0/$1]"

var atoms = []string{"a", "b", "c", "x", " ", "1", "2", "Z", ".", "\\d", "\\w", "\\s", "\\.", "\\*", "[abc]", "[a-c]", "[^a-c]", "[0-9]", "[[:alpha:]]", "\\pL", "\\p{Nd}"}
var quants = []string{"", "", "*", "+", "?", "*?", "+?", "??", "{2}", "{1,3}", "{0,2}", "{2,}"}
var anchors = []string{"^", "$", "\\b", "\\B", "\\A", "\\z"}
var flags = []string{"", "", "", "(?i)", "(?s)", "(?m)", "(?i)", "(?is)"}

func genAtom(r *rand.Rand, depth int) string {
	if depth > 0 && r.Intn(3) == 0 {
		// a group
		inner := genConcat(r, depth-1)
		switch r.Intn(3) {
		case 0:
			return "(" + inner + ")"
		case 1:
			return "(?:" + inner + ")"
		default:
			return "(?:" + inner + ")"
		}
	}
	return atoms[r.Intn(len(atoms))]
}

func genPiece(r *rand.Rand, depth int) string {
	a := genAtom(r, depth)
	q := quants[r.Intn(len(quants))]
	// Don't put a quantifier directly on an anchor; atoms here aren't anchors.
	return a + q
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
		// alternation
		s += "|" + genConcat(r, depth-1)
	}
	return s
}

func genRegex(r *rand.Rand) string {
	f := flags[r.Intn(len(flags))]
	return f + genConcat(r, 3)
}

var inputAlpha = []rune("abcxZ12 .\n\tαβΑΒ日")

func genInput(r *rand.Rand) string {
	n := r.Intn(12)
	rs := make([]rune, n)
	for i := range rs {
		rs[i] = inputAlpha[r.Intn(len(inputAlpha))]
	}
	return string(rs)
}

var altInputAlpha = []rune("abcxy12 AB\nΑ")

func genAltInput(r *rand.Rand) string {
	n := r.Intn(10)
	rs := make([]rune, n)
	for i := range rs {
		rs[i] = altInputAlpha[r.Intn(len(altInputAlpha))]
	}
	return string(rs)
}

func main() {
	r := rand.New(rand.NewSource(20260625))
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	enc := json.NewEncoder(w)

	npat := 1500
	// A second, independent stream of alternation-heavy patterns keeps the
	// original 1500 patterns (and their seed) unchanged.
	ra := rand.New(rand.NewSource(20260922))
	nalt := 300
	for k := 0; k < npat+nalt; k++ {
		var p string
		if k < npat {
			p = genRegex(r)
		} else {
			p = genAlternation(ra)
		}
		re, err := regexp.Compile(p)
		if err != nil {
			enc.Encode(Case{P: p, Err: true})
			continue
		}
		ni := progLen(p)
		for j := 0; j < 6; j++ {
			var in string
			if k < npat {
				in = genInput(r)
			} else {
				in = genAltInput(ra)
			}
			c := Case{
				P:     p,
				I:     in,
				Err:   false,
				M:     re.FindStringSubmatchIndex(in),
				All:   re.FindAllStringSubmatchIndex(in, -1),
				Repl:  re.ReplaceAllString(in, replT),
				Split: re.Split(in, -1),
				NI:    ni,
			}
			enc.Encode(c)
		}
	}
}
