// Command manifest writes test/data/MANIFEST.json to stdout: the Go and
// Unicode versions the corpora were recorded with, and each corpus's case
// count. The count comes from the corpus's {"count":N} trailer and is
// cross-checked against its number of lines. The Zig drivers assert their
// corpus matches it. Run via tools/regen.sh:
//
//	manifest test/data/cases.jsonl test/data/fuzz.jsonl ...
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"unicode"

	"zoptia0regex/tools/internal/corpus"
	"zoptia0regex/tools/internal/gen"
)

type manifest struct {
	GoVersion      string         `json:"go_version"`
	UnicodeVersion string         `json:"unicode_version"`
	Corpora        map[string]int `json:"corpora"`
}

func main() {
	if len(os.Args) < 2 {
		gen.Fatalf("usage: manifest corpus.jsonl...")
	}
	m := manifest{GoVersion: runtime.Version(), UnicodeVersion: unicode.Version, Corpora: map[string]int{}}
	for _, path := range os.Args[1:] {
		name := strings.TrimSuffix(filepath.Base(path), ".jsonl")
		m.Corpora[name] = count(path)
	}
	out, err := json.MarshalIndent(m, "", "  ")
	gen.Check(err)
	f := gen.Stdout()
	f.Write(out)
	f.WriteByte('\n')
	f.Close()
}

// count returns the corpus's trailer count after checking that it is the
// last line and that exactly that many case lines precede it.
func count(path string) int {
	data := gen.ReadFile(path)
	if !bytes.HasSuffix(data, []byte("\n")) {
		gen.Fatalf("%s: missing final newline", path)
	}
	lines := bytes.Split(bytes.TrimSuffix(data, []byte("\n")), []byte("\n"))
	last := lines[len(lines)-1]
	var t corpus.Trailer
	dec := json.NewDecoder(bytes.NewReader(last))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&t); err != nil {
		gen.Fatalf("%s: bad trailer %q: %v", path, last, err)
	}
	if t.Count != len(lines)-1 || t.Count == 0 {
		gen.Fatalf("%s: trailer says %d cases, file has %d lines", path, t.Count, len(lines)-1)
	}
	fmt.Fprintf(os.Stderr, "%s: %d cases\n", path, t.Count)
	return t.Count
}
