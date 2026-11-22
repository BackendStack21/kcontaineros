# Inside a container started with --read-only: every modifying tool on a
# read-only filesystem, kcontaineros and busybox side by side.
B=/bb/busybox
r() { for impl in /bin/ "$B "; do eval "$impl$*" >/dev/null 2>/tmp/e; rc=$?; $B printf '%-34s %-12s rc=%s %s\n' "$*" "${impl%% *}" $rc "$($B head -c 120 /tmp/e | $B tr '\n' '|')"; done; }
r touch /etc/new; r touch /etc/passwd; r mkdir /etc/new; r mkdir -p /etc/a/b; r mkdir -p /etc; r rm /etc/passwd; r rm -f /etc/passwd; r rm -rf /etc
r cp /etc/passwd /etc/new; r cp /etc/passwd /etc/group; r mv /etc/passwd /etc/p2; r ln /etc/passwd /etc/l; r ln -s x /etc/l; r chmod 600 /etc/passwd; r chown 0:0 /etc/passwd
r mv /etc/passwd /tmp/p; r cp /etc/passwd /tmp/p; r rm -rf /tmp/p /etc/passwd
echo "after: $($B ls /etc | $B tr '\n' ' ') passwd is $($B wc -c < /etc/passwd) bytes"
