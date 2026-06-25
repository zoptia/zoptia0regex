package main

import (
	"bufio"
	"encoding/json"
	"math/rand"
	"os"
	"regexp"
)

type Case struct {
	P     string   `json:"p"`
	I     string   `json:"i"`
	Err   bool     `json:"err"`
	M     []int    `json:"m"`
	All   [][]int  `json:"all"`
	Repl  string   `json:"repl"`
	Split []string `json:"split"`
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

func main() {
	r := rand.New(rand.NewSource(20260625))
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	enc := json.NewEncoder(w)

	npat := 1500
	for k := 0; k < npat; k++ {
		p := genRegex(r)
		re, err := regexp.Compile(p)
		if err != nil {
			enc.Encode(Case{P: p, Err: true})
			continue
		}
		repl := regexp.MustCompile(p) // same
		_ = repl
		for j := 0; j < 6; j++ {
			in := genInput(r)
			c := Case{
				P:     p,
				I:     in,
				Err:   false,
				M:     re.FindStringSubmatchIndex(in),
				All:   re.FindAllStringSubmatchIndex(in, -1),
				Repl:  re.ReplaceAllString(in, replT),
				Split: re.Split(in, -1),
			}
			enc.Encode(c)
		}
	}
}
