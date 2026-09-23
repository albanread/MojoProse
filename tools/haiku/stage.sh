#!/bin/bash
# Stage the Haiku build of the compiler for a Prose machine to use through
# HostFS: the compiler and its libraries with debug info stripped, the
# standard library's sources to precompile there, and the settings that
# point the compiler at all of it.
#
#   tools/haiku/stage.sh DEST [GUEST_DIR]
#
# DEST is a folder the machine shares (hvgpu --share); GUEST_DIR is where the
# guest sees it (default /HostFS/mojo-haiku). Build first:
#   ./bazelw build --config=haiku //Mojo/tools/mojo:mojo //Mojo:CompilerRT
#
# In the guest:
#   . GUEST_DIR/env.sh
#   mojo precompile -o "$MODULAR_MOJO_MAX_IMPORT_PATH/std.mojoc" GUEST_DIR/stdlib/std
#   mojo build hello.mojo
set -euo pipefail
DEST="${1:?usage: stage.sh DEST [GUEST_DIR]}"
GUEST="${2:-/HostFS/mojo-haiku}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/bazel-bin"
STRIP="$(dirname "$(readlink -f "$ROOT/bazel-MojoProse/external/+http_archive+clang-macos/bin/clang")")/llvm-strip"

[ -x "$STRIP" ] || { echo "stage: no llvm-strip at $STRIP" >&2; exit 1; }
file -L "$BIN/Mojo/tools/mojo/mojo" | grep -q 'ELF 64-bit.*aarch64' ||
	{ echo "stage: bazel-bin's mojo is not the Haiku build (build with --config=haiku)" >&2; exit 1; }

rm -rf "$DEST/bin" "$DEST/lib" "$DEST/stdlib"
mkdir -p "$DEST/bin" "$DEST/lib" "$DEST/stdlib"
"$STRIP" --strip-debug -o "$DEST/bin/mojo" "$BIN/Mojo/tools/mojo/mojo"
for lib in _solib_/_USupport/libMSupportGlobals.so \
		_solib_/_UAsyncRT/libAsyncRTRuntimeGlobals.so \
		Mojo/libKGENCompilerRTShared.so; do
	"$STRIP" --strip-debug -o "$DEST/lib/$(basename "$lib")" "$(readlink -f "$BIN/$lib")"
done
rsync -a --delete "$ROOT/Mojo/stdlib/std/" "$DEST/stdlib/std/"

# The compiler reads these as its modular.cfg settings (MODULAR_<section>_<key>).
# The precompiled standard library goes on the guest's own disk.
cat > "$DEST/env.sh" <<ENV
export PATH="$GUEST/bin:\$PATH"
export MODULAR_MOJO_MAX_PACKAGE_ROOT="$GUEST"
export MODULAR_MOJO_MAX_IMPORT_PATH=/boot/home/mojo/import
export MODULAR_MOJO_MAX_COMPILERRT_PATH="$GUEST/lib/libKGENCompilerRTShared.so"
export MODULAR_MOJO_MAX_LLD_PATH=/boot/system/bin/ld.lld
export MODULAR_MOJO_MAX_LINKER_DRIVER=/boot/system/bin/cc
mkdir -p /boot/home/mojo/import
ENV
ls -l "$DEST/bin" "$DEST/lib"
