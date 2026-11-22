#!/bin/sh
# examples/hello-http: does it build on the release image, run under init as
# nobody, answer, stop at once, and survive the README's hardened flags?
# Run from the repo root. Creates and removes kcos-audit-supply-http*.
set -u
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd); cd "$root"
IMG=kcos-audit-supply-http; C=kcos-audit-supply-http-c-$$
cleanup() { docker rm -f "$C" >/dev/null 2>&1; docker rmi -f "$IMG" >/dev/null 2>&1; }
trap cleanup EXIT; trap 'exit 130' INT TERM
echo "== build (BASE=kcontaineros)"
timeout 600 docker build --platform linux/arm64 --build-arg BASE=kcontaineros -t "$IMG" examples/hello-http >"$here/out/build-http.log" 2>&1; echo "rc=$?"
grep -nE 'Downloading|Updating|warning' "$here/out/build-http.log" | head
docker image inspect -f 'user={{.Config.User}} entrypoint={{json .Config.Entrypoint}} cmd={{json .Config.Cmd}} env={{json .Config.Env}} size={{.Size}}' "$IMG"
echo "== the binary is static"
timeout 60 docker run --rm --platform linux/arm64 --entrypoint /bin/sh "$IMG" -c 'ls -l /usr/local/bin/hello-http /data /data/status' 2>&1
echo "== run 1: defaults"
runit() {
  docker rm -f "$C" >/dev/null 2>&1
  timeout 60 docker run -d --platform linux/arm64 --name "$C" -p 127.0.0.1::8080 "$@" "$IMG" >/dev/null || { echo "start failed"; return; }
  port=$(docker port "$C" 8080 | sed 's/.*://')
  body=; for _ in $(seq 1 50); do body=$(curl -fsS --max-time 2 "http://127.0.0.1:$port/" 2>/dev/null) && break; sleep 0.2; done
  echo "body: $body"
  echo "headers: $(curl -sS -D - -o /dev/null --max-time 2 "http://127.0.0.1:$port/" | tr -d '\r' | tr '\n' '|')"
  timeout 30 docker exec "$C" ps
  timeout 30 docker exec "$C" cat /proc/1/status | grep -E '^(Uid|Gid|CapEff|CapBnd|NoNewPrivs|Seccomp):' | tr '\t' ' ' | tr '\n' ';'; echo
  echo "pid of hello-http status:"; timeout 30 docker exec "$C" sh -c 'cat /proc/2/status' 2>/dev/null | grep -E '^(Name|Uid|CapEff|NoNewPrivs|Seccomp):' | tr '\t' ' ' | tr '\n' ';'; echo
  t0=$(python3 -c 'import time; print(int(time.time()*1000))'); timeout 60 docker stop -t 10 "$C" >/dev/null; t1=$(python3 -c 'import time; print(int(time.time()*1000))')
  echo "docker stop: $((t1 - t0)) ms, exit code $(docker inspect -f '{{.State.ExitCode}}' "$C"), logs: $(docker logs "$C" 2>&1 | tr '\n' '|')"
  docker rm -f "$C" >/dev/null 2>&1
}
runit
echo "== run 2: README hardened flags (--read-only --cap-drop ALL --security-opt no-new-privileges --memory 64m --pids-limit 128 --ipc none)"
runit --read-only --cap-drop ALL --security-opt no-new-privileges --memory 64m --pids-limit 128 --ipc none
echo "== run 3: PORT=notaport (error path, exit status through init)"
timeout 60 docker run --rm --platform linux/arm64 -e PORT=notaport "$IMG"; echo "rc=$?"
echo "== the example on the sealed base: RUN needs a shell, so it must fail at the RUN step (README: sealed is for images without RUN steps)"
timeout 600 docker build --platform linux/arm64 --build-arg BASE=kcontaineros:sealed -t "$IMG-sealed" examples/hello-http 2>&1 | grep -E 'ERROR|not found|no such file' | head -3
docker rmi -f "$IMG-sealed" >/dev/null 2>&1
echo "== example Dockerfile against the README's own advice"
grep -nE '^(FROM|USER|CMD|ENTRYPOINT|COPY|RUN|ENV)' examples/hello-http/Dockerfile
