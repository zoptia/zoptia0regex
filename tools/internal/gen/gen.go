// Package gen holds the small amount of plumbing every generator shares:
// fail-loudly error handling and a buffered stdout whose write errors are
// reported instead of dropped.
package gen

import (
	"bufio"
	"fmt"
	"os"
)

// Check aborts the generator when err is non-nil. Generators produce
// committed golden data, so any I/O or encoding failure must stop the run
// rather than leave a silently truncated or partial output behind.
func Check(err error) {
	if err != nil {
		Fatalf("%v", err)
	}
}

// Fatalf prints a message to stderr and exits with status 1.
func Fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "%s: ", progName())
	fmt.Fprintf(os.Stderr, format, args...)
	fmt.Fprintln(os.Stderr)
	os.Exit(1)
}

func progName() string {
	if len(os.Args) == 0 {
		return "generator"
	}
	return os.Args[0]
}

// Output is a buffered writer over stdout. bufio.Writer errors are sticky,
// so formatting calls can ignore their results as long as Close is called:
// it flushes and aborts on the first error any earlier write hit.
type Output struct {
	*bufio.Writer
}

// Stdout returns a new Output writing to os.Stdout.
func Stdout() *Output {
	return &Output{bufio.NewWriterSize(os.Stdout, 1<<16)}
}

// Close flushes the buffer and aborts on any write error.
func (o *Output) Close() {
	Check(o.Flush())
}

// WriteFile writes data to path and aborts on failure.
func WriteFile(path string, data []byte) {
	Check(os.WriteFile(path, data, 0o644))
}

// ReadFile reads path and aborts on failure.
func ReadFile(path string) []byte {
	data, err := os.ReadFile(path)
	Check(err)
	return data
}
