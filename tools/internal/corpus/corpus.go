// Package corpus records Go's regexp behaviour as JSON Lines for the
// port's differential tests (test/*test.zig via test/difftest_common.zig).
//
// Every corpus shares one record shape (Case). Each line describes one
// (pattern, mode, input) triple:
//
//	p     pattern
//	mode  omitted for Perl (regexp.Compile), "longest" (Compile + Longest)
//	      or "posix" (CompilePOSIX)
//	err   Go's syntax.ErrorCode text when compilation fails, else omitted
//	ee    the failing compile's syntax.Error.Expr (the offending fragment
//	      of p), omitted when empty or longer than MaxInline
//	eeh   for a longer fragment instead of ee: its "LEN:HEX" hash (see lph)
//	msg   the failing compile's MustCompile (MustCompilePOSIX for the
//	      posix mode) panic message, omitted when longer than MaxInline
//	msgh  for a longer message instead of msg: its "LEN:HEX" hash
//	ni    len(prog.Inst) of syntax.Compile(syntax.Parse(p, flags).Simplify()),
//	      flags being syntax.Perl or syntax.POSIX as the mode compiles with
//	lp    LiteralPrefix() prefix, omitted when empty or longer than
//	      MaxInline
//	lph   for longer prefixes instead of lp: the prefix's length and
//	      64-bit FNV-1a hash, as "LEN:HEX" (a limit pattern's prefix can
//	      be megabytes)
//	lpc   LiteralPrefix() complete flag, omitted when false
//	i     input
//	m     FindStringSubmatchIndex(i)
//
// and, for corpora that exercise the find-all family, additionally
//
//	n     the limit passed to FindAll* and Split
//	t     the ReplaceAllString template
//	all   FindAllStringSubmatchIndex(i, n)
//	repl  ReplaceAllString(i, t)
//	split Split(i, n)
//
// Byte strings (p, ee, msg, lp, i, t, repl, split elements) are JSON strings when they
// are valid UTF-8 and arrays of byte values otherwise, so malformed UTF-8
// survives the round trip. The last line of every corpus is a trailer
// {"count":N} giving the number of case lines before it; the Zig drivers
// require it, so a truncated corpus fails instead of passing.
package corpus

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"os"
	"regexp"
	"regexp/syntax"
	"slices"
	"strings"
	"unicode/utf8"

	"zoptia0regex/tools/internal/gen"
)

// MaxPatternLen bounds a recorded pattern. Larger limit cases live in the
// port's src/limitstest.zig, which builds them at run time.
const MaxPatternLen = 16 << 10

// MaxInline is the longest literal prefix, error fragment or panic message
// recorded verbatim; longer ones are recorded as a length and hash.
const MaxInline = 1024

// inlineOrHash returns s for a verbatim field when it is at most MaxInline
// bytes long, and otherwise its "LEN:HEX" length and FNV-1a-64 hash.
func inlineOrHash(s string) (Bytes, string) {
	if len(s) <= MaxInline {
		return Bytes(s), ""
	}
	h := fnv.New64a()
	h.Write([]byte(s))
	return "", fmt.Sprintf("%d:%016x", len(s), h.Sum64())
}

// Bytes is a byte string that marshals as a JSON string when it is valid
// UTF-8 and as an array of byte values otherwise.
type Bytes string

// MarshalJSON implements json.Marshaler.
func (b Bytes) MarshalJSON() ([]byte, error) {
	if utf8.ValidString(string(b)) {
		var buf bytes.Buffer
		enc := json.NewEncoder(&buf)
		enc.SetEscapeHTML(false)
		if err := enc.Encode(string(b)); err != nil {
			return nil, err
		}
		return bytes.TrimRight(buf.Bytes(), "\n"), nil
	}
	vals := make([]int, len(b))
	for i := 0; i < len(b); i++ {
		vals[i] = int(b[i])
	}
	return json.Marshal(vals)
}

// Mode selects how a pattern is compiled.
type Mode int

const (
	// Perl is regexp.Compile (syntax.Perl, leftmost-first).
	Perl Mode = iota
	// Longest is regexp.Compile followed by Longest() (syntax.Perl flags,
	// leftmost-longest semantics).
	Longest
	// POSIX is regexp.CompilePOSIX (syntax.POSIX flags, leftmost-longest).
	POSIX
)

// Modes lists every mode, in the order the generators iterate them.
var Modes = []Mode{Perl, Longest, POSIX}

func (m Mode) String() string {
	switch m {
	case Perl:
		return "perl"
	case Longest:
		return "longest"
	case POSIX:
		return "posix"
	}
	return fmt.Sprintf("Mode(%d)", int(m))
}

// MarshalJSON implements json.Marshaler. Perl is the zero value and is
// omitted from records (omitempty).
func (m Mode) MarshalJSON() ([]byte, error) {
	if m < Perl || m > POSIX {
		return nil, fmt.Errorf("invalid mode %d", int(m))
	}
	return json.Marshal(m.String())
}

// Case is one corpus record; see the package comment for the fields.
type Case struct {
	P    Bytes  `json:"p"`
	Mode Mode   `json:"mode,omitempty"`
	Err  string `json:"err,omitempty"`
	EE   Bytes  `json:"ee,omitempty"`
	EEH  string `json:"eeh,omitempty"`
	Msg  Bytes  `json:"msg,omitempty"`
	MsgH string `json:"msgh,omitempty"`
	NI   int    `json:"ni,omitempty"`
	LP   Bytes  `json:"lp,omitempty"`
	LPH  string `json:"lph,omitempty"`
	LPC  bool   `json:"lpc,omitempty"`
	I    Bytes  `json:"i"`
	M    []int  `json:"m"`
	*AllOps
}

// AllOps holds the find-all family results of a Case.
type AllOps struct {
	N     int     `json:"n"`
	T     Bytes   `json:"t"`
	All   [][]int `json:"all"`
	Repl  Bytes   `json:"repl"`
	Split []Bytes `json:"split"`
}

// Compiled is a pattern compiled in one mode, with everything recorded
// about the compilation.
type Compiled struct {
	P    string
	Mode Mode
	Re   *regexp.Regexp // nil when compilation failed
	Err  string         // syntax.ErrorCode text, or "" on success
	EE   string         // syntax.Error.Expr of a failed compile
	Msg  string         // MustCompile / MustCompilePOSIX panic message
	NI   int
	LP   string
	LPC  bool
}

// SyntaxError returns the *syntax.Error of a compile error, aborting the
// generator if err is not one.
func SyntaxError(err error) *syntax.Error {
	var se *syntax.Error
	if !errors.As(err, &se) {
		gen.Fatalf("unexpected non-syntax error %T: %v", err, err)
	}
	return se
}

// mustPanic returns the value MustCompile (or MustCompilePOSIX) panics with
// for p, or "" when it does not panic.
func mustPanic(p string, mode Mode) (msg string) {
	defer func() {
		if r := recover(); r != nil {
			s, ok := r.(string)
			if !ok {
				gen.Fatalf("%q: MustCompile panicked with %T", p, r)
			}
			msg = s
		}
	}()
	if mode == POSIX {
		regexp.MustCompilePOSIX(p)
	} else {
		regexp.MustCompile(p)
	}
	return ""
}

// Compile compiles p in mode the way the regexp package does and records
// the outcome. It cross-checks the regexp entry point against a direct
// syntax.Parse (same error code, or both succeed) so ni is always the
// program regexp itself runs.
func Compile(p string, mode Mode) *Compiled {
	if len(p) > MaxPatternLen {
		gen.Fatalf("pattern of %d bytes exceeds MaxPatternLen", len(p))
	}
	c := &Compiled{P: p, Mode: mode}
	flags := syntax.Perl
	var re *regexp.Regexp
	var err error
	switch mode {
	case Perl, Longest:
		re, err = regexp.Compile(p)
	case POSIX:
		flags = syntax.POSIX
		re, err = regexp.CompilePOSIX(p)
	default:
		gen.Fatalf("invalid mode %d", int(mode))
	}
	sre, perr := syntax.Parse(p, flags)
	if err != nil {
		se := SyntaxError(err)
		c.Err, c.EE = string(se.Code), se.Expr
		if perr == nil || *SyntaxError(perr) != *se {
			gen.Fatalf("%q (%v): regexp error %v, syntax.Parse error %v", p, mode, err, perr)
		}
		// The drivers rebuild Error() from the code and fragment.
		if want := "error parsing regexp: " + c.Err + ": `" + c.EE + "`"; err.Error() != want {
			gen.Fatalf("%q: Error() %q is not %q", p, err.Error(), want)
		}
		c.Msg = mustPanic(p, mode)
		if !strings.HasSuffix(c.Msg, "): "+err.Error()) {
			gen.Fatalf("%q: MustCompile panic %q does not end in the error", p, c.Msg)
		}
		return c
	}
	if perr != nil {
		gen.Fatalf("%q (%v): regexp accepted, syntax.Parse failed: %v", p, mode, perr)
	}
	prog, err := syntax.Compile(sre.Simplify())
	gen.Check(err)
	c.NI = len(prog.Inst)
	if c.NI == 0 {
		gen.Fatalf("%q (%v): empty program", p, mode)
	}
	if mode == Longest {
		re.Longest()
	}
	c.Re = re
	c.LP, c.LPC = re.LiteralPrefix()
	return c
}

// Case records FindStringSubmatchIndex of input. For a pattern that failed
// to compile it records the error with an empty input.
func (c *Compiled) Case(input string) Case {
	out := Case{P: Bytes(c.P), Mode: c.Mode, Err: c.Err, NI: c.NI, LPC: c.LPC}
	out.LP, out.LPH = inlineOrHash(c.LP)
	if c.Re == nil {
		out.EE, out.EEH = inlineOrHash(c.EE)
		out.Msg, out.MsgH = inlineOrHash(c.Msg)
		return out
	}
	out.I = Bytes(input)
	out.M = c.Re.FindStringSubmatchIndex(input)
	// The drivers check match / findIndex against m; make sure that is
	// what Go itself returns for them.
	loc := c.Re.FindStringIndex(input)
	if (loc == nil) != (out.M == nil) || (loc != nil && !slices.Equal(loc, out.M[:2])) {
		gen.Fatalf("%q: FindStringIndex %v disagrees with FindStringSubmatchIndex %v", c.P, loc, out.M)
	}
	if c.Re.MatchString(input) != (out.M != nil) {
		gen.Fatalf("%q: MatchString disagrees with FindStringSubmatchIndex", c.P)
	}
	return out
}

// CaseAll records Case(input) plus the find-all family with limit n and
// replacement template t.
func (c *Compiled) CaseAll(input string, n int, t string) Case {
	out := c.Case(input)
	if c.Re == nil {
		return out
	}
	ops := &AllOps{N: n, T: Bytes(t)}
	ops.All = c.Re.FindAllStringSubmatchIndex(input, n)
	// The drivers check findAllIndex against the whole-match slots of all.
	idx := c.Re.FindAllStringIndex(input, n)
	if len(idx) != len(ops.All) || (idx == nil) != (ops.All == nil) {
		gen.Fatalf("%q: FindAllStringIndex disagrees with FindAllStringSubmatchIndex", c.P)
	}
	for k := range idx {
		if !slices.Equal(idx[k], ops.All[k][:2]) {
			gen.Fatalf("%q: FindAllStringIndex disagrees with FindAllStringSubmatchIndex", c.P)
		}
	}
	ops.Repl = Bytes(c.Re.ReplaceAllString(input, t))
	if parts := c.Re.Split(input, n); parts != nil {
		ops.Split = make([]Bytes, len(parts))
		for k, s := range parts {
			ops.Split[k] = Bytes(s)
		}
	}
	out.AllOps = ops
	return out
}

// Writer emits a corpus to stdout and appends the count trailer on Close.
type Writer struct {
	out   *gen.Output
	enc   *json.Encoder
	count int
}

// NewWriter returns a Writer on stdout.
func NewWriter() *Writer {
	out := gen.Stdout()
	enc := json.NewEncoder(out)
	enc.SetEscapeHTML(false)
	return &Writer{out: out, enc: enc}
}

// Write emits one case.
func (w *Writer) Write(c Case) {
	gen.Check(w.enc.Encode(c))
	w.count++
}

// Close writes the trailer and flushes, aborting on any write error.
func (w *Writer) Close() {
	gen.Check(w.enc.Encode(Trailer{Count: w.count}))
	w.out.Close()
	fmt.Fprintf(os.Stderr, "%d cases\n", w.count)
}

// Trailer is the last line of every corpus.
type Trailer struct {
	Count int `json:"count"`
}
