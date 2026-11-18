#!/bin/sh
# Regenerate the Unicode tables, the differential-test corpora and the
# benchmark workloads from Go (the golden reference for this port).
#
#   tools/regen.sh
#
# The reference is pinned to Go 1.27.1 / Unicode 17.0: GOTOOLCHAIN forces
# that exact toolchain (the go command downloads it if needed), whatever
# `go` is on PATH. Everything is generated into a temporary directory first
# and moved into place only after every generator succeeded, so a failing
# generator can never leave a truncated or partial output behind.
#
# Outputs (all committed; rerun only when a generator changes):
#   src/fold_table.zig        unicode.SimpleFold orbits (all of Unicode)
#   src/unicode_tables.zig    \p{...} category/script/fold/alias tables
#   test/data/cases.jsonl     curated differential corpus
#   test/data/fuzz.jsonl      randomized Perl-syntax corpus
#   test/data/longest.jsonl   randomized leftmost-longest / POSIX corpus
#   test/data/bytes.jsonl     byte-level corpus (malformed UTF-8, NULs, modes, limits)
#   test/data/MANIFEST.json   Go/Unicode versions and per-corpus case counts
#   bench/data/*              benchmark workloads and corpus
set -eu
cd "$(dirname "$0")/.."
root=$(pwd)

GO_REF=go1.27.1
export GOTOOLCHAIN="$GO_REF"
version=$(cd tools && go version)
case "$version" in
"go version $GO_REF "*) ;;
*)
	echo "regen.sh: need $GO_REF, got: $version" >&2
	exit 1
	;;
esac
echo "using $version"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zoptia0regex-regen.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/src" "$tmp/test" "$tmp/bench"

echo "building generators ..."
(cd tools && go build -o "$tmp/bin/" ./cmd/genfold ./cmd/genuni ./cmd/gencases ./cmd/genfuzz ./cmd/genlongest ./cmd/genbytes ./cmd/genbench ./cmd/manifest)

echo "generating Unicode tables ..."
"$tmp/bin/genfold" >"$tmp/src/fold_table.zig"
"$tmp/bin/genuni" >"$tmp/src/unicode_tables.zig"

for corpus in cases fuzz longest bytes; do
	echo "generating test/data/$corpus.jsonl ..."
	"$tmp/bin/gen$corpus" >"$tmp/test/$corpus.jsonl"
done
"$tmp/bin/manifest" "$tmp/test/cases.jsonl" "$tmp/test/fuzz.jsonl" "$tmp/test/longest.jsonl" "$tmp/test/bytes.jsonl" >"$tmp/test/MANIFEST.json"

echo "generating benchmark workloads ..."
"$tmp/bin/genbench" -dir "$tmp/bench"

# Every generator succeeded: install the outputs.
mv "$tmp/src/fold_table.zig" "$tmp/src/unicode_tables.zig" "$root/src/"
mv "$tmp/test/"* "$root/test/data/"
mv "$tmp/bench/"* "$root/bench/data/"
echo "done."
cat "$root/test/data/MANIFEST.json"
