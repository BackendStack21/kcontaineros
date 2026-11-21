X="a b"
echo "$X|\$X|${X}"
echo 'single $X "q"'
echo a\ b \$X "back\\slash" "q\"q"
echo "" | cat
echo pre"mid"'post'
echo $X$X
E=
echo :$E: :"$E": :${E:-def}: :${X:-def}: :${UNSET_VAR:-}:
echo lone $ dollar "$" end
echo $$ | /bb/busybox grep -c '^[0-9][0-9]*$'
echo line \
  continued
echo "dq line \
continued"
echo # comment
echo a#b
echo "multi
line"
S="  spaced  out "
/bb/busybox printf '<%s>' $S; echo
echo mid\
word
echo same-fd 1>&1
echo trailing\
