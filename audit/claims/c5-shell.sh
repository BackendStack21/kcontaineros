# The shell rows of the features table: see shcheck.py.
python3 $HERE/shcheck.py "$RES"
read -r _ a b c <<COUNTS
$(grep '^__COUNTS__' "$RES" | tail -1)
COUNTS
nclaims=$((nclaims + a)); ntests=$((ntests + b)); ndiff=$((ndiff + c))
grep -v '^__COUNTS__' "$RES" > "$RES.tmp"; mv "$RES.tmp" "$RES"
