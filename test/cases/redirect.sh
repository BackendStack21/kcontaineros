cd /t/redirect
echo one > f
echo two >> f
cat < f
echo three >f; cat f
echo err-to-out 2>&1 | cat
nope-cmd 2>&1 | cat
nope-cmd 2> errfile; cat errfile
echo to-stderr >&2
echo closed >&-; echo "rc=$?"
cat <&-; echo "rc=$?"
echo x > /nonexistent/dir/f; echo "rc=$?"
cat < /nonexistent; echo "rc=$?"
echo x >&nope; echo "rc=$?"
echo x >&9; echo "rc=$?"
echo fd3 3>f3 >&3; cat f3
X=1 > created; ls created
> also-created
ls also-created
: > f; ls -l f
cd /nonexistent 2> cderr; echo "rc=$?"; cat cderr
cd /tmp > /nonexistent/x; echo "rc=$?"
: 7> f7; echo seven >&7; echo "rc=$?"
F=/t/redirect/from-var
echo via-variable > $F; cat from-var
echo lost > $UNSET_TARGET; echo "rc=$?"
: 10> y10 > x10; echo "descriptors intact"
exec 5> f5
echo five >&5
exec 5>&-
cat f5
exec < f5
cat
exec 8>&1
exec > f6 2>&1
echo into-f6
nope-in-f6
exec >&8 2>&8
exec cat f6
