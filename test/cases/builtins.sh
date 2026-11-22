cd /tmp && pwd
cd; pwd
HOME=/etc
cd; pwd
unset HOME
cd; pwd
cd /nonexistent; echo "rc=$?"
export A=1 B=two
export NOVALUE
env | /bb/busybox grep -c '^[AB]='
A=changed
echo "$A"
unset A B
echo "[$A$B]"
K=v sh -c 'echo "prefix: $K"'
echo "after prefix: [$K]"
K=kept :
echo "builtin prefix persists: $K"
set -x
echo traced a b c d e f g
K=t true
set +x
set -e +e
set -- one "two words"; echo "$#: $2"
set three; echo "$#: $1"
PATH=/nonexistent
echo builtin-fallback
sh -c "echo nested-fallback"
nope; echo "rc=$?"
PATH=/bin
exec
echo after-empty-exec
exec nope-exec
