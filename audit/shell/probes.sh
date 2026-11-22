#!/bin/sh
# Hand-written cases behind the findings and the points read from src/sh.rs:
# each script is run by kcos /bin/sh and by busybox sh and printed as SAME or
# DIFF with both results.
#   sh audit/shell/probes.sh          without init (--entrypoint)
#   sh audit/shell/probes.sh init     under /sbin/init, as root, Landlock on
HERE=$(cd "$(dirname "$0")" && pwd)
IMG=${IMG:-kcos-audit}
if [ "$1" = init ]; then
  timeout 300 docker run --rm -i --platform linux/arm64 --name kcos-audit-shell-probes-$$ --memory 256m --pids-limit 128 \
    "$IMG" /bb/busybox sh -s < "$HERE/probes-in.sh"
else
  timeout 300 docker run --rm -i --platform linux/arm64 --name kcos-audit-shell-probes-$$ --memory 256m --pids-limit 128 \
    --entrypoint /bb/busybox "$IMG" sh -s < "$HERE/probes-in.sh"
fi
