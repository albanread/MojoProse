#!/bin/bash
# Run the standard library's tests on Prose, the way Bazel's mojo_test does:
# each file built with its target's flags, then run, with its environment.
#
#   run-stdlib-tests.sh MANIFEST TESTROOT OUTDIR [JOBS]
#
# MANIFEST is tools/haiku/stdlib-tests.py's output: one test a line, tab
# separated -- target name, source (relative to TESTROOT), compiler flags,
# whether assertions are on, the environment (K=V;K=V), other dependencies,
# and "incompatible" or "generated" for tests it cannot run. Results go to
# OUTDIR/results.tsv (RESULT, target, seconds) and each test's output to
# OUTDIR/logs/.
#
# Needs the compiler's settings (env.sh from tools/haiku/stage.sh) and the
# precompiled std and test_utils in its import path.
set -uo pipefail
MANIFEST="$1"
ROOT="$2"
OUT="$3"
JOBS="${4:-4}"
mkdir -p "$OUT/logs"

run_one() {
	local name src copts asserts env other unrunnable
	# Tab is whitespace to read, which would merge empty fields; the unit
	# separator is not.
	IFS=$'\x1f' read -r name src copts asserts env other unrunnable \
		<<< "${1//$'\t'/$'\x1f'}"
	local id="${src%/*}_${name}"
	id="${id//\//_}"
	local log="$OUT/logs/$id.log"
	local start=$SECONDS

	if [ -n "$unrunnable" ]; then
		printf 'SKIP\t%s\t%s\n' "$id" "$unrunnable"; return
	fi
	if [ -n "$other" ]; then
		printf 'SKIP\t%s\tneeds %s\n' "$id" "$other"; return
	fi
	case "$src" in
		gpu/*) printf 'SKIP\t%s\tneeds a GPU\n' "$id"; return ;;
		python/*) printf 'SKIP\t%s\tneeds Python\n' "$id"; return ;;
	esac

	local work="/tmp/mojo-stdlib-tests/$id"
	rm -rf "$work"
	mkdir -p "$work"
	cd "$work" || return
	# As under Bazel, each test has its own TEST_TMPDIR, and the compiler
	# keeps its cache there: one shared cache outgrows a small guest disk.
	export TEST_TMPDIR="$work"

	local flags=($copts)
	[ "$asserts" = yes ] && flags+=(-D ASSERT=all)
	if ! timeout 900 mojo build "${flags[@]}" "$ROOT/$src" -o "$work/test" \
			> "$log" 2>&1; then
		printf 'BUILDFAIL\t%s\t%ds\n' "$id" $((SECONDS - start)); return
	fi

	local envs=()
	[ -n "$env" ] && IFS=';' read -r -a envs <<< "$env"
	local status
	env "${envs[@]}" timeout 600 "$work/test" >> "$log" 2>&1
	status=$?
	if [ $status -eq 0 ]; then
		printf 'PASS\t%s\t%ds\n' "$id" $((SECONDS - start))
	elif [ $status -eq 124 ]; then
		printf 'TIMEOUT\t%s\t%ds\n' "$id" $((SECONDS - start))
	else
		printf 'FAIL(%d)\t%s\t%ds\n' $status "$id" $((SECONDS - start))
	fi
	cd / && rm -rf "$work"
}
export -f run_one
export ROOT OUT

xargs -d '\n' -P "$JOBS" -I{} bash -c 'run_one "$1"' _ {} < "$MANIFEST" \
	> "$OUT/results.tsv"
cut -f1 "$OUT/results.tsv" | sed 's/(.*//' | sort | uniq -c
