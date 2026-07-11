#!/bin/sh
# Regenerate the Unicode tables and the differential-test corpora from the
# locally-installed Go toolchain (the golden reference for this port).
#
#   tools/regen.sh        # regenerate everything
#
# Outputs (all committed; rerun only when a generator changes):
#   src/fold_table.zig      faithful unicode.SimpleFold table (all of Unicode)
#   src/unicode_tables.zig  curated \p{...} category/script tables
#   src/cases.jsonl         curated differential corpus
#   src/fuzz.jsonl          large random differential corpus
#   src/longest.jsonl       POSIX leftmost-longest corpus
#   src/bench.jsonl + src/bench_*.txt  benchmark workloads and corpus
set -e
cd "$(dirname "$0")/.."

echo "generating Unicode fold table ..."
( cd tools && go run genfold.go && mv fold_table.zig ../src/fold_table.zig )

echo "generating Unicode class tables ..."
( cd tools && go run genuni.go && mv unicode_tables.zig ../src/unicode_tables.zig )

echo "generating curated differential corpus (src/cases.jsonl) ..."
( cd tools && go run gencases.go ) > src/cases.jsonl

echo "generating random fuzz corpus (src/fuzz.jsonl) ..."
( cd tools && go run genfuzz.go ) > src/fuzz.jsonl

echo "generating leftmost-longest corpus (src/longest.jsonl) ..."
( cd tools && go run genlongest.go ) > src/longest.jsonl

echo "generating benchmark corpus (src/bench*.{jsonl,txt}) ..."
( cd tools && go run genbench.go ) > src/bench.jsonl

echo "done. counts:"
wc -l src/cases.jsonl src/fuzz.jsonl src/longest.jsonl src/bench.jsonl
