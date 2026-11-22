#!/usr/bin/env bash
# (d) Unknown options, operand counts and number parsing for every applet.
# Prints every case that exited 0 so that they can be read against the list
# of documented options; the complete log is out/options.tsv.
. "$(dirname "$0")/lib.sh"
under_init options.sh --tmpfs /work:size=16m --pids-limit 8192 --memory 512m > "$OUT/options.tsv" 2> "$OUT/options.err"
echo "cases run: $(grep -c $'\t' "$OUT/options.tsv")"
echo "--- single-letter options that exited 0 (documented: ls -l -a, rm -r -f, mkdir -p, ln -s, env -i, kill -DIGITS, uname -a -n -r -m -s):"
awk -F'\t' '/^==/{exit} $3==0 {print}' "$OUT/options.tsv"
echo "--- single-letter cases that timed out (143/124) or crashed (>=100):"
awk -F'\t' '/^==/{exit} $3>=100 {print}' "$OUT/options.tsv"
echo "--- remaining sections, complete:"
awk '/^==/{p=1} p' "$OUT/options.tsv"
[ -s "$OUT/options.err" ] && { echo "--- harness stderr (first 20 lines):"; head -20 "$OUT/options.err"; }
exit 0
