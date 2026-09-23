#!/bin/bash
# Assemble the Haiku arm64 sysroot that MojoProse's Bazel toolchain
# cross-compiles against, from a Haiku build tree used strictly read-only.
#
#   tools/haiku/make-sysroot.sh [haiku tree] [destination]
#
# Defaults: /Volumes/HaikuSrc/haiku -> /Volumes/HaikuSrc/mojoprose-sysroot-arm64.
# The destination must be on a case-sensitive volume: libstdc++'s <clocale>
# asks for <locale.h>, and a case-insensitive search finds the Locale Kit's
# os/locale/Locale.h first. HaikuSrc is case-sensitive; xc is not.
#
# A real copy, not symlinks: Bazel hashes the sysroot's contents into its
# cache keys, and a copy does not change under the build when the Haiku tree
# is rebuilt. Rerun this after a Haiku build that changes headers or
# libraries, and Bazel refetches.
#
# Layout is what clang's Haiku driver (clang/lib/Driver/ToolChains/Haiku.cpp)
# expects under --sysroot: headers in boot/system/develop/headers, start files
# and libraries in boot/system/develop/lib and boot/system/lib. On top of the
# Haiku packages it adds what GCC would otherwise supply from its own install:
# libstdc++'s headers, GCC's own headers, crtbeginS.o and crtendS.o.
set -euo pipefail
HAIKU="${1:-/Volumes/HaikuSrc/haiku}"
DEST="${2:-/Volumes/HaikuSrc/mojoprose-sysroot-arm64}"
GEN="$HAIKU/generated"
PKGS="$GEN/objects/haiku/arm64/packaging/packages_build/regular"
DEVEL="$PKGS/hpkg_-haiku_devel.hpkg/contents"
RUNTIME="$PKGS/hpkg_-haiku.hpkg/contents"
GCCSYS="$(ls -d "$GEN"/build_packages/gcc_syslibs-*-arm64 | head -1)"
GCCDEV="$(ls -d "$GEN"/build_packages/gcc_syslibs_devel-*-arm64 | head -1)"
GCCLIB="$(ls -d "$GEN"/cross-tools-arm64/lib/gcc/aarch64-unknown-haiku/* | head -1)"

for d in "$DEVEL" "$RUNTIME" "$GCCSYS" "$GCCDEV" "$GCCLIB"; do
	[ -d "$d" ] || { echo "make-sysroot: missing $d (is the Haiku tree built?)" >&2; exit 1; }
done

rm -rf "$DEST.new"
SYS="$DEST.new/boot/system"
mkdir -p "$SYS/develop" "$SYS/lib"

# -P keeps the packages' relative symlinks (develop/lib/libbe.so ->
# ../../lib/libbe.so), which resolve inside the copy.
cp -RP "$DEVEL/develop/headers" "$SYS/develop/headers"
cp -RP "$GCCDEV/develop/headers/c++" "$SYS/develop/headers/c++"
cp -RP "$GCCDEV/develop/headers/gcc" "$SYS/develop/headers/gcc"
mkdir -p "$SYS/develop/lib"
cp -RP "$DEVEL/develop/lib/." "$SYS/develop/lib/"
cp -RP "$GCCDEV/develop/lib/." "$SYS/develop/lib/"
cp -p "$GCCLIB/crtbeginS.o" "$GCCLIB/crtendS.o" "$SYS/develop/lib/"
cp -RP "$RUNTIME/lib/." "$SYS/lib/"
cp -RP "$GCCSYS/lib/." "$SYS/lib/"

# A link into a package this sysroot does not carry -- libroot_debug.so points
# at the debug libroot, which is its own package -- is dropped, and named.
find "$DEST.new" -type l ! -exec test -e {} \; -print | while read -r link; do
	echo "make-sysroot: dropping $(basename "$link") -> $(readlink "$link") (not in these packages)"
	rm "$link"
done

rm -rf "$DEST"
mv "$DEST.new" "$DEST"
echo "sysroot ready: $DEST ($(du -sh "$DEST" | cut -f1)," \
	"$(ls "$DEST/boot/system/develop/lib" | wc -l | tr -d ' ') develop libs)" \
	| sed "s|$DEST.new|$DEST|"
