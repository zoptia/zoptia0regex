package main

import (
	"bufio"
	"encoding/json"
	"math/rand"
	"os"
	"regexp"
)

type LCase struct {
	P   string  `json:"p"`
	I   string  `json:"i"`
	M   []int   `json:"m"`
	All [][]int `json:"all"`
}

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

var linput = []rune("abcxZ12 αβ")

func lgenInput(r *rand.Rand) string {
	n := r.Intn(10)
	rs := make([]rune, n)
	for i := range rs {
		rs[i] = linput[r.Intn(len(linput))]
	}
	return string(rs)
}

func main() {
	r := rand.New(rand.NewSource(424242))
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	enc := json.NewEncoder(w)
	for k := 0; k < 2500; k++ {
		p := lgenConcat(r, 3)
		re, err := regexp.Compile(p)
		if err != nil {
			continue
		}
		re.Longest() // switch to leftmost-longest
		for j := 0; j < 6; j++ {
			in := lgenInput(r)
			enc.Encode(LCase{P: p, I: in, M: re.FindStringSubmatchIndex(in), All: re.FindAllStringSubmatchIndex(in, -1)})
		}
	}
}
