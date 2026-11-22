#!/bin/bash
# Runs the whole init audit. From the repo root: audit/init/run_all.sh
# Needs the images kcontaineros, kcontaineros:sealed and kcos-audit, Docker
# on an ARM64 host, bash, python3, GNU timeout and objdump.
# 07_pid_reuse.sh cycles through 4194304 PIDs and takes 10 to 20 minutes;
# SKIP_REUSE=1 leaves it out. 06_flood.sh keeps up to 90 processes busy for
# about five minutes in all.
cd "$(dirname "$0")"
./build.sh >/dev/null || exit 1
for s in 01_exit_status 02_signals 03_stop_signals 04_tty 05_reaping 06_flood 08_misc 09_no_alloc; do
    echo "##### $s"; ./$s.sh
done
[ -n "${SKIP_REUSE:-}" ] || { echo "##### 07_pid_reuse"; ./07_pid_reuse.sh; }
echo "Remove the helper images with: docker rmi kcos-audit-init-img kcos-audit-init-sealed"
