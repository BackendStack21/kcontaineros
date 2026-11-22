#!/bin/bash
# Exit status of init for every way the command can end.
# Each case is its own container with init as PID 1.
cd "$(dirname "$0")"; . ./lib.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# 256 exit codes and 64 signals, eight containers at a time.
one() { timeout 120 docker run --rm --platform linux/arm64 "$IMG" "${@:2}" >"$tmp/$1.out" 2>&1; echo $? >"$tmp/$1.rc"; }
export -f one; export IMG tmp
seq 0 255 | xargs -P 8 -I{} bash -c 'one exit{} /bb/kh exit {}'
seq 1 64 | xargs -P 8 -I{} bash -c 'one sig{} /bb/kh selfkill {}'
for s in 3 4 6 7 8 11 24 25 31; do echo $s; done | xargs -P 8 -I{} bash -c 'one core{} /bb/kh selfkill {} core'

for c in $(seq 0 255); do ok "exit code $c is passed through" "$c:" "$(cat $tmp/exit$c.rc):$(cat $tmp/exit$c.out)"; done
for s in $(seq 1 64); do
    case $s in
        17|18|23|28) want=99 ;;          # ignored by default: the helper lives and exits 99
        19|20|21|22) want=skip ;;        # stop signals: see 03_stop_signals.sh
        *) want=$((128+s)) ;;
    esac
    [ $want = skip ] && continue
    ok "command killed by signal $s gives $want" "$want:" "$(cat $tmp/sig$s.rc):$(cat $tmp/sig$s.out)"
done
for s in 3 4 6 7 8 11 24 25 31; do
    ok "command dumping core on signal $s gives $((128+s))" "$((128+s)):" "$(cat $tmp/core$s.rc):$(cat $tmp/core$s.out)"
done

# Exec failures.
long=$(printf 'n%.0s' $(seq 1 300))
huge=/$(printf 'p/%.0s' $(seq 1 2100))x
ok "ENOENT, by path" "kcontaineros: /bb/nothing: no such file or directory[127]" "$(r $IMG /bb/nothing)"
ok "ENOENT, through PATH" "kcontaineros: nothing: no such file or directory[127]" "$(r $IMG nothing)"
ok "ENOENT, dangling link" "kcontaineros: /bb/dangling: no such file or directory[127]" "$(r $IMG /bb/dangling)"
ok "ENOENT, missing interpreter" "kcontaineros: /bb/badinterp: no such file or directory[127]" "$(r $IMG /bb/badinterp)"
ok "ENOTDIR" "kcontaineros: /bb/kh/x: not a directory[127]" "$(r $IMG /bb/kh/x)"
ok "EACCES, no x bit" "kcontaineros: /bb/noexec: permission denied[126]" "$(r $IMG /bb/noexec)"
ok "EACCES, a directory" "kcontaineros: /bb/adir: permission denied[126]" "$(r $IMG /bb/adir)"
ok "ENOENT, missing file in a writable directory" "kcontaineros: /tmp/x: no such file or directory[127]" "$(r $IMG /tmp/x)"
ok "ENOEXEC, garbage" "kcontaineros: /bb/garbage: exec format error[126]" "$(r $IMG /bb/garbage)"
ok "ENOEXEC, empty file" "kcontaineros: /bb/empty: exec format error[126]" "$(r $IMG /bb/empty)"
ok "ENOEXEC, text without #!" "kcontaineros: /bb/noshebang: exec format error[126]" "$(r $IMG /bb/noshebang)"
ok "ELOOP" "kcontaineros: /bb/loop: too many levels of symbolic links[126]" "$(r $IMG /bb/loop)"
ok "ENAMETOOLONG, component" "kcontaineros: /bb/$long: file name too long[126]" "$(r $IMG /bb/$long)"
ok "ENAMETOOLONG, path of 4201 bytes" "kcontaineros: $huge: file name too long[126]" "$(r $IMG "$huge")"
ok "name of 300 bytes through PATH" "kcontaineros: $long: file name too long[126]" "$(r $IMG "$long")"
ok "empty command name" "kcontaineros: : no such file or directory[127]" "$(r $IMG "")"
ok "a #! script in a program directory runs" "script ran 2[0]" "$(r $IMG /bb/script a b)"
# E2BIG: init is started with an argument list at the kernel's limit; the
# command is a #! script, whose exec needs room for the interpreter as well.
ok "E2BIG" "bigexec: N bytes of padding
kcontaineros: /bb/bigscript: argument list too long[126]" "$(r $IMG /bb/kh bigexec /sbin/init /bb/bigscript | sed 's/bigexec: [0-9]* bytes/bigexec: N bytes/')"
# "--" handling and the default command.
ok "-- is skipped once" "kcontaineros: --: no such file or directory[127]" "$(r $IMG -- --)"
ok "no command: /bin/sh, which reads an empty stdin" "[0]" "$(r --entrypoint /sbin/init $IMG </dev/null)"
ok "sealed image without command: no /bin/sh" "kcontaineros: /bin/sh: no such file or directory[127]" "$(r kcontaineros:sealed)"
summary
