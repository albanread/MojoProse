#!/bin/sh
# Builds libmojobe and the bridge's test programs on Prose and runs them:
# bridge_check and threads_check, then both again under libroot's guarded
# heap (a use after free or a double delete faults there), then the
# programs that must not compile. Dots is built, for dots_smoke.py, which
# drives it from the Mac.
#   run.sh WORK_DIR SOURCE_DIR
# SOURCE_DIR holds bridge/, tests/ and examples/ as Haiku/ does; WORK_DIR
# is emptied and built in. Needs `mojo` on the PATH (env.sh).
work=${1:?work directory}
source=${2:?the Haiku directory}
link="-Xlinker -L$work -Xlinker -lmojobe -Xlinker -lbe -Xlinker -rpath -Xlinker $work"
rm -rf "$work" && mkdir -p "$work/tmp" || exit 1
cp -R "$source/bridge/haiku" "$source/bridge/libmojobe" "$source/tests" "$work"/
cp "$source/examples/dots/dots.mojo" "$work"/
cd "$work" || exit 1
export TEST_TMPDIR=$work/tmp

c++ -O2 -Wall -Wextra -Wpointer-arith -shared -fPIC -o libmojobe.so \
	libmojobe/mojobe.cpp -lbe 2>&1 | head -20
for program in dots tests/bridge_check tests/threads_check; do
	mojo build -I . $program.mojo -o $(basename $program) $link 2>&1 | head -30
done
ls -l libmojobe.so dots bridge_check threads_check | awk '{print $5, $NF}'

status=0
for test in bridge_check threads_check; do
	./$test > $test.out 2>&1
	grep -v "^PASS" $test.out
	tail -1 $test.out | grep -q "SELFTEST PASS" || status=1
done
echo "--- under the guarded heap"
for test in bridge_check threads_check; do
	LD_PRELOAD=/boot/system/lib/libroot_debug.so MALLOC_DEBUG=g ./$test \
		> $test.guarded 2>&1
	echo "$test: exit $? $(tail -1 $test.guarded)"
	tail -1 $test.guarded | grep -q "SELFTEST PASS" || status=1
done
sh tests/must_not_compile.sh "$work" | grep -v "^PASS" || true
sh tests/must_not_compile.sh "$work" | tail -1 | grep -q "PASS" || status=1
[ $status = 0 ] && echo "RUN PASS" || echo "RUN FAIL"
