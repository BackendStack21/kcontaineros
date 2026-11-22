#!/usr/bin/env bash
# Sample the wall clock inside a container twice a second for SECS seconds
# (default 1500) and report every jump of more than 5 s between samples.
# Used while test/e2e.sh runs: its control check runs `date -s 2001-01-01`
# as privileged root without init, and the clock is not namespaced.
#   audit/claims/clockwatch.sh [SECS] > audit/claims/out/clock.log
SECS=${1:-1500}
timeout $((SECS + 60)) docker run --rm --platform linux/arm64 --name kcos-audit-claims-clock --entrypoint /bb/busybox kcos-audit \
  sh -c "n=0; prev=\$(/bb/busybox date -u +%s); while [ \$n -lt $((SECS * 2)) ]; do now=\$(/bb/busybox date -u +%s); d=\$((now - prev)); if [ \$d -gt 5 ] || [ \$d -lt -5 ]; then echo \"jump: \$prev -> \$now (\$(/bb/busybox date -u -d @\$prev '+%F %T') -> \$(/bb/busybox date -u -d @\$now '+%F %T'))\"; fi; prev=\$now; n=\$((n+1)); /bb/busybox sleep 0.5; done; echo samples=\$n"
