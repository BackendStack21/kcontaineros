#!/bin/sh
# Rerun the whole shell audit from the repository root. Needs the images
# kcos-audit and kcontaineros, python3, GNU timeout. About 25 minutes.
#   sh audit/shell/run-all.sh
cd "$(dirname "$0")" || exit 1
mkdir -p work
for seed in 21 22 23; do
  python3 diff.py --seed $seed --count 3000 --show 0 | tee work/diff-$seed.txt
  for mode in file c stdin; do
    python3 reduce.py $seed SILENT,SIGNAL,SYNTAX-AFTER-RUN $mode > work/red-$seed-$mode.txt 2>&1
  done
done
python3 bucket.py 21 22 23 | tee work/buckets.txt
for seed in 11 12; do python3 fuzz.py --seed $seed --count 24000 | tee work/fuzz-$seed.txt; done
sh stress.sh | tee work/stress.txt
sh quadratic.sh | tee work/quadratic.txt
sh probes.sh | tee work/probes.txt
sh probes.sh init | tee work/probes-init.txt
(cd ../.. && bash audit/shell/interactive.sh) | tee work/interactive.txt
sh env.sh | tee work/env.txt    # needs room on Docker's disk to install gcc in an alpine container
