# Lists every directory (outside /proc and /sys, which are never written to
# by this audit) in which the current user can really create a file.
export PATH=${B:-/bb}:$PATH
find / -xdev -type d 2>/dev/null > /dev/null
for d in $(find / \( -path /proc -o -path /sys \) -prune -o -type d -print 2>/dev/null); do
  f="$d/.kcos-audit-escape-user-$$"
  if ( : > "$f" ) 2>/dev/null; then echo "WRITABLE $d"; rm -f "$f"; fi
done
echo "SWEEP-DONE"
