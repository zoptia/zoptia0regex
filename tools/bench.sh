#!/bin/sh
# Run the Zig and Go benchmarks side by side and regenerate the generated
# blocks of BENCHMARKS.md and README.md (tools/cmd/benchtable). Run it on an
# otherwise idle machine; it takes a few minutes.
#
#   tools/bench.sh            # measure and update the docs
#   BENCH_OUT=dir tools/bench.sh   # also keep the raw TSVs in dir
#
# The Go side is built with the reference toolchain (go1.27.1, like the
# corpora) into a binary, so `go run` build time never enters a timing.
# benchtable aborts if any case's single-run result differs between Go and
# Zig.
set -eu
cd "$(dirname "$0")/.."
root=$(pwd)

export GOTOOLCHAIN=go1.27.1
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zoptia0regex-bench.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "building Go harnesses ($(cd tools && go version)) ..."
(cd tools && go build -o "$tmp/" ./cmd/benchgo ./cmd/benchscratchgo ./cmd/benchtable)

echo "running zig build bench ..."
zig build bench >"$tmp/zig.tsv"
echo "running zig build bench-scratch ..."
zig build bench-scratch >"$tmp/zigscratch.tsv"
echo "running Go benchmark ..."
"$tmp/benchgo" -data bench/data >"$tmp/go.tsv"
echo "running Go scratch benchmark ..."
"$tmp/benchscratchgo" -data bench/data >"$tmp/goscratch.tsv"

cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null ||
	sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null | head -n 1 ||
	true)
"$tmp/benchtable" -go "$tmp/go.tsv" -zig "$tmp/zig.tsv" \
	-goscratch "$tmp/goscratch.tsv" -zigscratch "$tmp/zigscratch.tsv" \
	-cpu "${cpu:-unknown}" -update "$root/BENCHMARKS.md" -update "$root/README.md"

if [ -n "${BENCH_OUT:-}" ]; then
	mkdir -p "$BENCH_OUT"
	cp "$tmp"/*.tsv "$BENCH_OUT/"
	echo "raw results in $BENCH_OUT"
fi
