set -e
echo a
false || echo "or keeps going"
false && echo never
echo b
false
echo not-reached
