#!/bin/sh
# Empirical access matrix: 8 runs of matrix-inner.sh
#   (nobody | root) x (default | --privileged) x (init | control without init)
# Results: results/matrix-USER-PRIV-MODE.tsv, then compare.py prints the table.
# Run from the repo root after audit/landlock/build.sh.
set -u
here=$(cd "$(dirname "$0")" && pwd)
IMG=kcos-audit-landlock-img
V=kcos-audit-landlock-vol
mkdir -p "$here/results"
cleanup() { for i in 1 2 3 4 5; do docker volume rm -f $V$i >/dev/null 2>&1; done; }
trap cleanup EXIT
runc() { timeout 180 docker run --rm --platform linux/arm64 "$@"; }

for user in nobody root; do for priv in default privileged; do for mode in init control; do
    cleanup
    # Fresh volumes each run: /vol, /usr/nested, /app/nested, /w/nested with kv+kd; one with a file for /topmnt.
    for i in 1 2 3 4; do
        runc -u 0 --entrypoint /bb/busybox -v $V$i:/v $IMG sh -c 'cp /bb/lp /v/kv && chmod 777 /v/kv /v && mkdir /v/kd && chmod 1777 /v/kd' || echo "setup failed" >&2
    done
    runc -u 0 --entrypoint /bb/busybox -v ${V}5:/v $IMG sh -c 'echo data > /v/file && chmod 666 /v/file' || echo "setup failed" >&2
    [ $user = root ] && u=0:0 || u=65534:65534
    [ $priv = privileged ] && p=--privileged || p=
    [ $mode = control ] && e="--entrypoint /bb/busybox" || e=
    [ $mode = control ] && cmd="sh -s" || cmd="/bb/busybox sh -s"
    out="$here/results/matrix-$user-$priv-$mode.tsv"
    runc -i -u $u $p $e -e MODE=$mode -e KCOS_EXEC=/bb:/app/bin \
        -v ${V}1:/vol -v ${V}2:/usr/nested -v ${V}3:/app/nested -v ${V}4:/w/nested \
        --mount type=volume,src=${V}5,dst=/topmnt,volume-subpath=file \
        --tmpfs /tfs:exec,mode=1777 --tmpfs /tfsnoexec:mode=1777 \
        $IMG $cmd < "$here/matrix-inner.sh" > "$out" 2> "$out.err"
    echo "$user $priv $mode: $(wc -l < "$out" | tr -d ' ') attempts, exit $?, stderr $(wc -c < "$out.err" | tr -d ' ') bytes"
done; done; done
python3 "$here/compare.py"
