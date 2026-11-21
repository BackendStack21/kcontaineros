echo "$#|$1|$2|$3|[$4]"
/bb/busybox printf '<%s>' "$@"; echo
/bb/busybox printf '<%s>' $@; echo
/bb/busybox printf '<%s>' "$*"; echo
/bb/busybox printf '<%s>' $*; echo
/bb/busybox printf '<%s>' pre"$@"post; echo
/bb/busybox printf '<%s>' ${2}; echo
shift
echo "$#|$1"
shift 2
echo "$#|[$1]"
/bb/busybox printf '<%s>' "$@" x; echo
/bb/busybox printf '<%s>' "${@:-dflt}"; echo
shift
echo "rc=$?"
shift nope
echo "rc=$?"
echo ${10} "${0}" | /bb/busybox grep -c params
