true && echo and-yes
false && echo and-skipped
false || echo or-yes
true || echo or-skipped
true || echo a && echo left-assoc-1
false && echo a || echo left-assoc-2
false &&
  echo skipped-after-newline
true ||
  echo skipped-too
echo "status after skipped: $?"
sh -c "exit 3"; echo "rc=$?"
sh -c "exit 300"; echo "rc=$?"
false; echo "rc=$?"
echo a; echo b ;
: ignored args
nope-command; echo "rc=$?"
/nope/command; echo "rc=$?"
/etc/passwd; echo "rc=$?"
sleep 0.2 & sleep 0.1 &
wait
echo waited
true &
sleep 0.2
echo x | cat | cat
false | true; echo "pipe rc=$?"
true | false; echo "pipe rc=$?"
echo piped |
  cat
cd /tmp | cat
exit 5 | cat
echo "still here: $?"
exit 9
echo not-reached
