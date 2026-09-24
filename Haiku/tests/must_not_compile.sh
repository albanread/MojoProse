#!/bin/sh
# Programs the bridge must refuse: each file in must_not_compile/ names, in
# its first line, the error `mojo build` must give. Runs on Prose; prints
# PASS or FAIL for each, then `MUST-NOT-COMPILE PASS n/n` or `... FAIL`.
#   must_not_compile.sh BRIDGE_DIR (holding the haiku package)
here=$(dirname "$0")/must_not_compile
bridge=${1:?the directory holding the haiku package}
passed=0 failed=0
for f in "$here"/*.mojo; do
	expect=$(head -1 "$f" | sed 's/^# expect: //')
	out=$(mojo build -I "$bridge" "$f" -o /tmp/must_not_compile.$$ 2>&1)
	if [ -e /tmp/must_not_compile.$$ ]; then
		echo "FAIL: $(basename "$f") compiled"
		failed=$((failed + 1))
		rm -f /tmp/must_not_compile.$$
	elif printf '%s' "$out" | grep -qF "$expect"; then
		echo "PASS: $(basename "$f"): $expect"
		passed=$((passed + 1))
	else
		echo "FAIL: $(basename "$f"): not the error expected:"
		printf '%s\n' "$out" | grep error | head -5
		failed=$((failed + 1))
	fi
done
if [ $failed = 0 ]; then
	echo "MUST-NOT-COMPILE PASS $passed/$passed"
else
	echo "MUST-NOT-COMPILE FAIL $passed/$((passed + failed))"
fi
