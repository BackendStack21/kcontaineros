# Runs inside the container (busybox sh). Prints one line per case:
#   APPLET <TAB> ARGS <TAB> exit <TAB> effect <TAB> first line of stderr
B=/bb/busybox
W=/work
T="$B timeout 5"
fresh() { cd /; $B rm -rf $W/f; $B mkdir $W/f; cd $W/f; echo data > a; echo data2 > b; $B mkdir d; }
effect() { # what changed in the scratch directory
  e=""
  [ -e a ] || e="$e a-gone"
  [ -e new ] && e="$e new-made"
  [ "$($B cat b 2>/dev/null)" = data2 ] || e="$e b-changed"
  echo "${e:-none}"
}
report() { # app, args-as-text, exit
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(effect)" "$($B head -c 200 $W/err | $B tr '\n\t' '| ')"
}
# every printable ASCII character but the dash itself as an option letter
CHARS='! " # $ % & ( ) * + , . / 0 1 2 3 4 5 6 7 8 9 : ; < = > ? @ A B C D E F G H I J K L M N O P Q R S T U V W X Y Z [ \ ] ^ _ ` a b c d e f g h i j k l m n o p q r s t u v w x y z { | } ~'
set -f
for app in cat chmod chown cp env kill ln ls mkdir mv ps pwd rm sleep touch uname; do
  for c in $CHARS "'"; do
    fresh
    o="-$c"
    case $app in
      cat) set -- "$o" a;;
      chmod) set -- "$o" 644 a;;
      chown) set -- "$o" 0:0 a;;
      cp|mv|ln) set -- "$o" a new;;
      env|ps|pwd|uname) set -- "$o";;
      kill) $B sleep 30 & set -- "$o" $!;;
      ls) set -- "$o" .;;
      mkdir) set -- "$o" new;;
      rm|touch) set -- "$o" a;;
      sleep) set -- "$o" 0;;
    esac
    $T /bin/$app "$@" >$W/out 2>$W/err </dev/null; rc=$?
    report $app "$*" $rc
    [ $app = kill ] && { $B kill -9 $! 2>/dev/null; wait; }
  done
done
echo "== SECOND POSITION AND LONG OPTIONS"
while IFS='|' read -r app args; do
  [ -z "$app" ] && continue
  fresh
  eval "set -- $args"
  $T /bin/$app "$@" >$W/out 2>$W/err </dev/null; rc=$?
  report $app "$args" $rc
done <<'CASES'
uname|-a -Z
uname|-s -n
uname|-a extra
uname|-sn
uname|--
uname|--all
uname|-s -s -s -s
ls|-l -Z .
ls|--all .
ls|-la -Z .
ls|-l --help
rm|-f -Z a
rm|-rf --no-preserve-root a
rm|--force a
mkdir|-p -m 700 new
mkdir|--parents new
ln|-s -f a new
ln|-sf a new
ln|--symbolic a new
cp|-r d new
cp|-a a new
cp|--recursive d new
cp|-p a new
mv|-f a new
mv|-n a b
touch|-c new
touch|-t 202001010000 a
touch|-d now a
chmod|-R 755 d
chmod|u+x a
chmod|+x a
chmod|a=r a
chmod|--reference=b a
chown|-R 0:0 d
chown|-h 0:0 a
chown|root a
chown|root:root a
chown|0.0 a
env|-0
env|--ignore-environment
env|-i -Z
env|-u
env|-iu X
env|-u X -Z
env|-C / pwd
env|-S 'pwd'
kill|-l
kill|-L
kill|--help
kill|-s
kill|-n 9 1234567
kill|--signal TERM 1234567
kill|-TERM -q 1234567
sleep|--help
sleep|-- 0
sleep|0 --
pwd|-P
pwd|-L
pwd|--
pwd|extra
ps|aux
ps|-ef
ps|-o pid
ps|--
cat|-n a
cat|-A a
cat|-u a
cat|-- -n
cat|--help
echo|--help
echo|--
true|--help
true|-Z
false|--help
false|--version
CASES
echo "== OPERAND COUNTS"
while IFS='|' read -r app args; do
  [ -z "$app" ] && continue
  fresh
  eval "set -- $args"
  $T /bin/$app "$@" >$W/out 2>$W/err </dev/null; rc=$?
  report $app "$args" $rc
done <<'CASES'
chmod|
chmod|644
chmod|644 --
chmod|-- 644
chmod|-- 644 --
chmod|-- 644 -- a
chmod|644 -- -- 
chmod|'' a
chown|
chown|0
chown|0 --
chown|-- 0:0 --
chown|'' a
chown|: a
chown|0: a
chown|:0 a
cp|
cp|a
cp|a b new
cp|a a
cp|a d d
cp|-- a
cp|-- a new
cp|a -- new
mv|
mv|a
mv|a b new
mv|a a
mv|-- a
ln|
ln|a
ln|a new extra
ln|-s a
ln|-s
ln|a d
ln|-s a d
mkdir|
mkdir|-p
mkdir|--
mkdir|''
mkdir|-p ''
rm|
rm|-f
rm|-r
rm|--
rm|-f --
rm|''
rm|-f ''
rm|-rf ''
touch|
touch|--
touch|''
sleep|
sleep|--
sleep|''
kill|
kill|--
kill|-9
kill|-s TERM
kill|-s TERM --
kill|''
kill|-9 ''
ls|''
ls|-- -l
cat|''
env|''
env|=x
env|A=1 B=2
uname|''
uname|-
pwd|''
ps|''
CASES
echo "== NUMBERS"
while IFS='|' read -r app args; do
  [ -z "$app" ] && continue
  fresh
  $B sleep 30 & P=$!
  eval "set -- $args"
  $T /bin/$app "$@" >$W/out 2>$W/err </dev/null; rc=$?
  alive=dead; $B kill -0 $P 2>/dev/null && alive=alive
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$app" "$args" "$rc" "$(effect) victim-$alive mode=$($B stat -c %a:%u:%g a 2>/dev/null)" "$($B head -c 200 $W/err | $B tr '\n\t' '| ')" "$($B head -c 80 $W/out | $B tr '\n\t' '| ')"
  $B kill -9 $P 2>/dev/null; wait
done <<'CASES'
kill|0
kill|-0 0
kill|-1
kill|-- -1
kill|-9 -1
kill|-9 -- -1
kill|-s KILL -- -1
kill|-9 -- -$P
kill|-- -$P
kill|-$P
kill|4294967295
kill|4294967296
kill|4294967297
kill|$((4294967296 + P))
kill|-0 $((4294967296 + P))
kill|18446744073709551615
kill|18446744073709551616
kill|99999999999999999999999999999999999999
kill|2147483647
kill|2147483648
kill|-0 2147483647
kill|+$P
kill|" $P"
kill|"$P "
kill|0x10
kill|0$P
kill|-0 0$P
kill|-0 00000000000000000000000000$P
kill|$P.0
kill|١٢٣
kill|１２３
kill|-0 $P
kill|-0 $P 0 $P
kill|-64 $P
kill|-65 $P
kill|-s 65 $P
kill|-s -9 $P
kill|-s 4294967305 $P
kill|-4294967305 $P
kill|-18446744073709551625 $P
kill|-s SIGKILL $P
kill|-SIGKILL $P
kill|-SIGSIGKILL $P
kill|-s kill $P
kill|-s SIG $P
kill|-SIG $P
kill|-s '' $P
kill|-s 009 $P
kill|-s ９ $P
kill|-ALRM $P
kill|-s PIPE $P
kill|-s 0 $P
kill|-s
kill|-s 9
sleep|0
sleep|0.01
sleep|.01
sleep|0.
sleep|.
sleep|-1
sleep|-0
sleep|+0
sleep|0x1
sleep|1e-3
sleep|0,1
sleep|0.0000000001
sleep|0.00000000000000000000000000000000000000000000000000000001
sleep|0.0s
sleep|0.0m
sleep|0h
sleep|0d
sleep|0w
sleep|0ms
sleep|0ss
sleep|s
sleep|m
sleep|.s
sleep|0.-
sleep|0./
sleep|0.:
sleep|0.1.1
sleep|0. 
sleep|"0 "
sleep|" 0"
sleep|0 0 0
sleep|0 x
sleep|x 0
sleep|18446744073709551615
sleep|18446744073709551616
sleep|18446744073709551615 1
sleep|9223372036854775808
sleep|213503982334602d
sleep|213503982334601d 86400
sleep|0.9999999999999 0.9999999999 
sleep|٠
sleep|０
sleep|0.٠
sleep|NaN
sleep|-inf
sleep|Infinity
sleep|INF
chmod|0 a
chmod|7777 a
chmod|07777 a
chmod|00644 a
chmod|10000 a
chmod|8 a
chmod|-1 a
chmod|+644 a
chmod|0x1ff a
chmod|644 a b nonexistent
chmod|６４４ a
chmod|"644 " a
chmod|4755 a
chown|0:0 a
chown|4294967294:4294967294 a
chown|4294967295:0 a
chown|0:4294967295 a
chown|4294967296:0 a
chown|18446744073709551616:0 a
chown|-1:-1 a
chown|-- -1:-1 a
chown|+0:+0 a
chown|0:0:0 a
chown|00000000000000000000000:0 a
chown|０:０ a
chown|0x0:0 a
chown|0 a nonexistent b
CASES
