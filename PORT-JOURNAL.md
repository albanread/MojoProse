# MojoProse — Mojo on Haiku (Prose), arm64

Running record of the port. Newest entry at the bottom.

**Goal:** the Mojo compiler runs **on Prose** as a Haiku development tool:
`mojo build` and `mojo run` inside the Prose virtual machine, on Haiku arm64,
producing native Haiku programs. It is built on the Mac with Bazel,
cross-compiled for Haiku.

**Scope:** the Mojo compiler, its C++ substrate (Support, AsyncRT, MLRT,
Config, Cache, Init), the standard library, CPU code generation, and a bridge
to the Haiku (Be) API so Mojo programs can open windows.

**Out of scope:** MAX, GPU backends, Python interop. **No telemetry and no
crash reporting** — both serve Modular, not a Haiku development tool.

**Upstream:** `modular/modular` @ `b3e9394` (2026-09-23, Mojo 1.2.0.dev),
shallow. Remote `upstream`; work on branch `prose`.

**Not based on MojoCocoa.** That compiler is modified extensively for Cocoa
and Darwin; this port starts from the original.

---

## G0 — Recon (2026-09-23)

### What exists already

- **The Prose side:** a Haiku arm64 cross toolchain (GCC 13.3,
  `/Volumes/HaikuSrc/haiku/generated/cross-tools-arm64`), a sysroot of the
  built packages (`HaikuArmQemu/prosewriter/app/sysroot`), clang 23 and lld
  running *inside* Prose, and a guest harness (`scripts/run-machine.sh`, the
  portal's `execute`).
- **Proof that Mojo code runs on Prose** (HaikuArmQemu `tools/mojo-spike`):
  a Mojo object compiled for `aarch64-unknown-haiku`, linked by Haiku's cross
  gcc against a stand-in runtime, printed on Prose. That used MojoCocoa's
  compiler and is superseded here, but it settled three things: LLVM's AArch64
  backend emits correct Haiku ELF, Haiku's toolchain links it, and the loader
  runs it.

### The layout upstream has now

The compiler moved from `KGEN/` into `Mojo/`: `Mojo/lib` (346 files),
`Mojo/include`, `Mojo/tools/mojo`, the standard library in `Mojo/stdlib/std`.
The build is Bazel only; `//Mojo:mojo` builds the compiler and the standard
library (`Mojo/docs/compiler/WorkingInOSRepo.md`). `.bazelrc` builds `dbg` by
default.

### Porting surface — measured

| area | files | `__APPLE__` | `__linux__` | `_WIN32` |
|---|---|---|---|---|
| `Mojo/lib` | 346 | 2 | 0 | 5 |
| `Mojo/tools` | 66 | 2 | 0 | 4 |
| `Support` | 319 | 14 | 8 | 28 |
| `AsyncRT` | 63 | 4 | 1 | 4 |
| `Config`, `Cache`, `Init` | 19 | 0 | 0 | 0 |

About twenty C++ files branch on the platform; LLVM's Support library does the
rest of the OS abstraction, and LLVM already knows Haiku. Nothing mentions
Haiku yet.

The standard library refuses an unknown OS at compile time
(`CompilationTarget.unsupported_target_error`): 22 sites in 9 files, plus 33
Linux/macOS branches, about a dozen files outside `gpu/`. OS detection reads
the triple (`_os() == "linux"`), so `is_haiku()` needs no compiler change.

### The toolchain: a cross build is structurally possible

`bazel/internal/cc-toolchain`: hermetic clang (LLVM 22) and lld per *exec*
platform (`linux-aarch64`, `linux-x86_64`, `macos`); the toolchains are
registered with `exec_compatible_with` only, and the `--target=` flag and the
sysroot are selected by the *target* platform. So the macOS clang can already
be aimed elsewhere. Haiku needs: a target platform (`@platforms//os:haiku`),
`--target=aarch64-unknown-haiku`, a Haiku sysroot, and Haiku branches where
the arguments differ. Build-time tools (tablegen, the host `mojo` that builds
the standard library) stay in the exec configuration, on the Mac.

### Third-party dependencies of interest

`abseil-cpp`, `fmt`, `zlib-ng`, `zstd`, `xxhash`, `nlohmann_json`,
`tomlplusplus`, `robin_map`, `tcmalloc` (Linux-only), `crashpad`,
`opentelemetry-cpp`, `grpc`, `protobuf`, `curl`. The last five came in through
telemetry and crash reporting — see the first change below. Which of the rest
`//Mojo:mojo` really links is for G1's dependency query.

### Decisions

| decision | why |
|---|---|
| Start from upstream, not MojoCocoa | MojoCocoa's compiler is modified extensively for Cocoa and Darwin |
| Build on the Mac, cross-compile for Haiku | Bazel does not run on Haiku; the Mac has the cache and the cores |
| No MAX, no GPU | MAX is for GPU programming |
| **No telemetry, no crash reporting** | They serve Modular. Removed in `63f0050`: the switches answer false, the OTLP HTTP exporters, the endpoints and crashpad are gone from code and build |
| Bazel output root `/Volumes/xc/bazel-mojoprose`; MojoCocoa's repository cache shared | An LLVM build would fill the OS disk; downloads are content-addressed |
| `-c opt` | Upstream defaults to `dbg`, which MojoCocoa found cannot link its shared LLVM |

### The ladder

| gate | goal | done when |
|---|---|---|
| G0 | recon | this entry |
| G1 | upstream builds on the Mac, without telemetry | `bazel-bin/…/mojo` runs `hello.mojo` on the Mac; `//Mojo:mojo` links none of crashpad, curl, protobuf, grpc |
| G2 | a Haiku target in the toolchain | a plain `cc_binary`, cross-built by Bazel, runs on Prose |
| G3 | LLVM and MLIR for Haiku | LLVM's own tools (`llc --version`) run on Prose |
| G4 | the compiler for Haiku | `mojo --version` runs on Prose |
| G5 | the standard library knows Haiku | `mojo build hello.mojo` **on Prose** makes a program that runs there |
| G6 | the runtime and the tests | `mojo run` (the JIT) works on Prose; the stdlib's CPU tests run there with a recorded pass count |
| G7 | the bridge | a Mojo program opens a window on Prose — see `Haiku/docs/bridge-design.md` |
| G8 | shipping | the compiler as a package in the Prose image |

---

## G1 — Upstream on the Mac (2026-09-23, in progress)

### First build: 3 minutes, then a macOS 27 trap

`./bazelw build //Mojo:mojo` (with `local.bazelrc`: output root on `xc`,
MojoCocoa's repository cache shared, `--config=build-mojo`, `-c opt`) resolved
the module graph and started compiling, then failed linking an exec-configuration
tool:

```
ld64.lld: error: undefined symbol: memset
ld64.lld: error: undefined symbol: operator delete[](void*, unsigned long)
```

Nothing to do with the port. This Mac now runs **macOS 27**, and Xcode's
`MacOSX27.sdk` ships a `usr/lib/libSystem.tbd` whose targets are
`x86_64-macos`, `arm64e-macos`, `arm64e.x1-macos` — **no plain `arm64-macos`**.
Apple's `ld` links arm64 code against an arm64e stub; LLVM 22's `ld64.lld` does
not, so every libSystem symbol is undefined. (`libc++.tbd` still lists
`arm64-macos`, which is why only some symbols were missing.)

The Command Line Tools still carry `MacOSX26.0.sdk`, whose `libSystem.tbd`
lists `arm64-macos`. Upstream's `macos_sysroot_repository` asks
`xcrun --show-sdk-path` under `DEVELOPER_DIR` and refetches when that changes,
so one machine-local line fixes it, with no source change:

```
common --repo_env=DEVELOPER_DIR=/Library/Developer/CommandLineTools
```

Programs built against the 26 SDK run on 27. The condition to watch: when the
Command Line Tools move to the 27 SDK, this breaks again, and the fix becomes
either rewriting the copied stubs to add `arm64-macos` (what Apple's `ld`
effectively assumes) or an `lld` that accepts arm64e stubs.

MojoCocoa builds against the same SDK rule and will hit this the next time its
sysroot is refetched.

---

## G2 — Pre-check: the build's clang makes Haiku programs (2026-09-23)

Before touching Bazel's toolchain, the facts it will encode, proved by hand
with the build's own hermetic clang
(`external/+http_archive+clang-macos/bin/clang++`, 22.1.4) on a C++ program
using libstdc++, `std::thread` and Haiku's `get_system_info`:

```
hello from clang 22 for Haiku: 4 threads joined, 4 CPUs      (on Prose)
```

What it took — every one found by failing first:

1. **A sysroot**, `tools/haiku/make-sysroot.sh`: a copy of the Haiku build's
   `haiku_devel` and `haiku` packages, `gcc_syslibs(_devel)` for libstdc++'s
   headers and libraries, and `crtbeginS.o`/`crtendS.o` from the cross GCC's
   install (clang names them on every Haiku link; no package carries them).
   The one dangling link, `develop/lib/libroot_debug.so`, points into the debug
   package and is dropped.
2. **A case-sensitive volume for it.** On `/Volumes/xc` (Journaled HFS+,
   case-insensitive) libstdc++'s `<clocale>` asked for `<locale.h>`, and the
   search found Haiku's Locale Kit `os/locale/Locale.h` first, because clang
   searches `os/locale` before `posix`. On Haiku's BFS the lookup misses and
   falls through to `posix/locale.h`. The sysroot therefore lives on the
   case-sensitive `/Volumes/HaikuSrc` (`/Volumes/HaikuSrc/mojoprose-sysroot-arm64`).
3. **libstdc++'s headers by name**: `-nostdinc++ -isystem …/c++ -isystem
   …/c++/aarch64-unknown-haiku -isystem …/c++/backward`. clang's Haiku driver
   finds them only through an installed GCC.
4. **Haiku's program layout**: `-z max-page-size=4096 -z common-page-size=4096
   -z noseparate-code`. With lld's 64 KB defaults the program exited 255
   before `main` ("Could not map image: Bad data", as Prose's own clang 23
   found — HaikuArmQemu memory, patch 0077).

### What this means for the Bazel wiring

Bazel's execroot and sandboxes are on `xc`, which is case-insensitive, and a
sandbox symlinks each input file. A sysroot copied into an external repository
would meet the `Locale.h` trap again inside the sandbox. So the Haiku toolchain
points `--sysroot` at the absolute path on `HaikuSrc`, allowed through
`allowlist_absolute_include_directories`, with a stamp of the sysroot's
contents in the toolchain's arguments so a new sysroot re-keys the actions.
The alternative, an output root on a case-sensitive volume, is kept for the
case where this one fails.

---

## G1 — Done: upstream builds and runs on the Mac (2026-09-23)

With the SDK fixed, `./bazelw build //Mojo:mojo` completed: **1,030 s**,
7,129 actions compiled on this M4 Max, the rest from the action cache and the
disk cache. `./bazelw run //Mojo:mojo -- run hello.mojo`:

```
hello from upstream Mojo, built from source: sum of squares 285
```

**Telemetry is out of the build.** `cquery 'deps(//Mojo/tools/mojo:mojo-full)'`
names no crashpad, curl, protobuf, grpc or OTLP exporter (its 14 "curl" hits
are `usr/include/curl/*.h` inside the macOS SDK copy, not a dependency). What
remains of OpenTelemetry is its SDK behind `Support:Telemetry`'s local file
exporters, which never run: the public telemetry headers use SDK types, so
it stays until that is worth restructuring.

**For G4**, the same query shows what the Haiku compiler must leave out:
`//Mojo:MojoLLDB` (the debugger; LLDB has no Haiku support) and a bundled
Python 3.13 (Python interop, out of scope).

## G2 — Done: Bazel cross-builds C++ for Haiku (2026-09-23)

```
./bazelw build --platforms=//:haiku-aarch64-platform \
    //bazel/internal/cc-toolchain/smoke:hello_haiku
hello from clang 22 for Haiku: 4 threads joined, 4 CPUs      (on Prose)
```

What went in:

- `//:haiku_aarch64` (config setting) and `//:haiku-aarch64-platform`, on
  `@platforms//os:haiku`, which the platforms module already has.
- `haiku_sysroot_repository.bzl`: the sysroot by absolute path from
  `--repo_env=HAIKU_SYSROOT`, checked for the files clang needs, and stamped
  (a hash of names and sizes) into every Haiku compile as
  `-DMOJOPROSE_HAIKU_SYSROOT=…`, so a new sysroot re-keys them.
- The toolchain: the Mac's clang tools for a Haiku target (it is a cross
  build), `--sysroot` with `allowlist_absolute_include_directories`, and a
  Haiku branch in every per-OS choice of `args/BUILD.bazel`: the triple,
  sections, `-mcpu=apple-m1`, libstdc++'s headers, Haiku's link flags, rpath,
  `--gc-sections`.

Four things found on the way, each by failing:

1. `rules_cc`'s `set_soname` is declared Linux-only; Haiku has its own copy,
   `:haiku_set_soname`.
2. `-stdlib=libstdc++` goes unused once the headers are named with
   `-nostdinc++`, and upstream makes unused arguments errors. libstdc++ is
   clang's default for Haiku, so it is not passed.
3. **clang's Haiku driver links every program `-shared`**, as Haiku programs
   are, and swallows `-pie`; upstream's `-Wl,-pie` for executables reaches the
   linker directly and lld refuses both. `-pie` is now Linux and macOS only.
4. The driver chooses `--enable-new-dtags` (`DT_RUNPATH`), which Haiku's
   loader reads, and the Linux branch's `--disable-new-dtags` override was
   not carried over.

The Mac build is untouched by all of it: `//Mojo:mojo` afterwards is 9,165
action-cache hits and nothing compiled.

**For G3**, LLVM's own Bazel configuration (`utils/bazel/.../llvm/config.bzl`)
must learn Haiku: today it would give a Haiku build Linux's `HAVE_GETAUXVAL`,
`HAVE_MALLINFO` and execinfo `HAVE_BACKTRACE` — none of which Haiku has — and
the native triple of its last default, `x86_64-unknown-linux-gnu`. Haiku does
have `sbrk`, `st_mtim`, `dladdr`, `posix_spawn` and, in its `gnu/` headers,
`pthread_{get,set}name_np`. A patch beside upstream's musl one.

---

## G3 — Done: LLVM and MLIR run on Prose (2026-09-23)

```
llc --version            LLVM version 24.0.0git … Default target: aarch64-unknown-haiku
llc hello.ll → .o, linked by Prose's clang:   hello from LLVM running on Haiku!
mlir-opt --canonicalize: arith.addi %a, 0  →  return %arg0
```

All on Prose, built by Bazel on the Mac: all of LLVM compiled for Haiku in
about four minutes (1,876 actions), MLIR in under six, **with no change to
any LLVM or MLIR source file**. What LLVM's CMake discovers on Haiku by
probing, LLVM's Bazel overlay hard-codes per OS, and Haiku fell through to
Linux. `bazel/public-patches/llvm-haiku.patch`, beside upstream's musl patch:

- `haiku_defines`: POSIX without execinfo's `HAVE_BACKTRACE`, plus
  `_GNU_SOURCE` (Haiku declares `pthread_{get,set}name_np` in `gnu/`),
  `HAVE_SBRK`, `HAVE_STRUCT_STAT_ST_MTIM_TV_NSEC` — read from Haiku's headers
  and libraries, not guessed.
- The native triple **`aarch64-unknown-haiku`**: the overlay's last default is
  `x86_64-unknown-linux-gnu`, which a compiler on Haiku would have targeted.
- Libraries: none of Linux's `-pthread -ldl -lm` or `-lrt` (libroot is all
  of them), but `-lbsd -lnetwork` for `Support`, as CMake does — `wait4` is in
  Haiku's libbsd and sockets in libnetwork. The first link failed on `wait4`.

### The finding: Haiku could not load clang's thread-locals

The first `llc` was refused by Haiku's loader: "Troubles relocating: Bad data".
It carried five `R_AARCH64_TLSDESC` relocations — TLS descriptors, which is
all clang generates for a `thread_local` on arm64 — and Haiku's arm64
`runtime_loader` knew only the traditional `TLS_DTPMOD64`/`TLS_DTPREL64` that
GCC uses. lld could not relax them away, because clang's Haiku driver links
every program `-shared`, and clang 22 rejects `-mtls-dialect` for Haiku.

It was not ours alone: a six-line program using `thread_local` and
`std::call_once`, built **on Prose by Prose's own clang 23**, failed the same
way. Every clang-built C++ program on Prose that touched thread-local storage
— including through libstdc++'s `call_once` — could not load.

`-femulated-tls` was tried and rejected: it cannot reach libstdc++'s own
thread-locals (`std::__once_callable`), which GCC built as native TLS.

The fix is in Haiku: **patch 0132**, TLS descriptors in the arm64
`runtime_loader`. A descriptor's second word packs the module and the offset;
the resolver, in assembly, asks `get_tls_address()` for the calling thread's
copy and returns its distance from `TPIDR_EL0`, saving every register a C++
call may clobber, as the descriptor ABI requires. Its test
(HaikuArmQemu `tools/tlstest`, built on Prose by Prose's clang) passes 6/6:
the program's own thread-local, one across a library boundary, one in a
library loaded by `dlopen`, `std::call_once`, and eight threads each with its
own copies. With it, `llc` loads unchanged.

**For G4:** `Host CPU: (unknown)` — LLVM has no host-CPU detection for Haiku,
and Mojo defaults its target CPU to the host's.

## G4 — Done: the compiler runs on Prose (2026-09-23)

`//Mojo/tools/mojo:mojo`, cross-built with `--config=haiku`, runs on Prose:

```
$ /HostFS/mojo-haiku/bin/mojo --version
Mojo 1.2.0.dev0 (deadbeef)
```

(`deadbeef` is upstream's placeholder for an unstamped build.) The binary is
867 MB as linked, 145 MB with `llvm-strip --strip-debug`, and needs two of the
build's own libraries beside it in `../lib`: `libMSupportGlobals.so` and
`libAsyncRTRuntimeGlobals.so`. Otherwise it links only Haiku's: libroot,
libstdc++, libgcc_s, libbsd, libnetwork.

### What stood between analysis and a binary

The first compile (`-k`) failed 1,650 times, in five kinds:

| errors | cause | fix |
|---|---|---|
| 1,572 | the layering check refuses headers no module map declares, and the sysroot is outside the execroot | the sysroot repository lists its headers as textual headers, by absolute path, for the builtin module map (`3b64e93`) |
| 65 | `PlatformUtils.h`: "Could not determine platform" | `MODULAR_HAIKU` (`0117af1`) |
| 11 | Haiku's libstdc++ defaults to the COW string ABI, which needs default-constructible allocators | `-D_GLIBCXX_USE_CXX11_ABI=1` for Haiku: its libstdc++ ships both ABIs (`9d351f7`) |
| 1 | abseil's `GetTID()` casts `pthread_t`, a pointer on Haiku | `find_thread(NULL)`, via `single_version_override` (`5e8b2ad`) |
| 2 | `std::aligned_alloc` absent; no `<sys/ucontext.h>` | `0117af1` |

With those the second build compiled every one of the 3,734 actions without
an error: LLVM, MLIR, lld, clang's libraries, OpenTelemetry's API and all of
Mojo's own C++. Then Mojo's host probe, which answered "Unsupported
platform." for CPU model, cache sizes, memory and OS version (`b194729`):
the answers are those arm64 Linux gives where Haiku has no source.

### Measured: what CPU the guest sees

Under Apple's hypervisor every core's `MIDR_EL1`, as Haiku's
`get_cpu_topology_info()` reports it, is `0x610f0000`: Apple's implementer
code with the **part number cleared**. LLVM cannot tell an M1 from an M4 by
it, and has no Haiku branch in `sys::getHostCPUName()` anyway, so the host
CPU is `generic` (ARMv8.0) and Mojo, which targets the host CPU by default,
would compile for it. Every Apple processor is an M1 or later — the floor
Prose's own C and C++ builds already use (`-mcpu=apple-m1`). For G5.

## G5 — Done: Mojo programs are built on Prose (2026-09-23)

On Prose, by the Haiku-built compiler, linked by Prose's own `cc` (clang 23)
and `ld.lld`:

```
$ mojo precompile -o $MODULAR_MOJO_MAX_IMPORT_PATH/std.mojoc std    # 14.7 s
$ mojo build hello.mojo && ./hello
Hello from Mojo on Prose
$ mojo build stdlib_check.mojo && ./stdlib_check | tail -1
SELFTEST PASS 31/31
```

The standard library is precompiled **on Prose**: a `.mojoc` holds
non-elaborated code and is not tied to a target, so nothing target-specific
crosses from the Mac. `tools/haiku/stage.sh` lays out what a machine needs
through HostFS — the compiler, its three libraries, the stdlib's sources, and
`env.sh` with the `MODULAR_MOJO_MAX_*` settings (the compiler reads
`MODULAR_<section>_<key>` as `modular.cfg` keys).

Times on Prose (8 vCPUs, M4 Max host, the compiler run from HostFS): stdlib
precompile 14.7 s; `mojo build` of hello 2.6 s cold, 0.5 s with the compile
cache warm; of the check program 5.0 s cold, 0.8 s warm.

### Two faults at startup

- `SecureRandomBytesGenerator` had no Haiku branch; its error tripped an
  assertion in `createLocalIDs()` on every start. Haiku has POSIX
  `getentropy()` (`c622593`).
- That call was the telemetry context gathering a host profile — CPU,
  memory, a machine id hashed from the network cards' addresses, a session
  id — for resource attributes only an exporter would send. With telemetry
  off, which it always is here, none of it is gathered now (`595b6db`).

### The standard library's Haiku facts

Measured against Haiku's headers with the compiler's own clang (constants
read from a compiled probe), except errno, probed on Prose:

| what | Linux | Haiku |
|---|---|---|
| errno | 1, 2, ... | status codes from INT_MIN: ENOENT -2147459069; 65 of 150 names absent |
| errno location | `__errno_location()` | `_errnop()` |
| `CLOCK_REALTIME` / `MONOTONIC` | 0 / 1 | -1 / 0 (and no `MONOTONIC_RAW`) |
| `struct stat` | glibc's | 128 bytes, `st_mode` at 16, times at 48–96 |
| `struct dirent` name | offset 19 | offset 26, flexible |
| `struct passwd` | …gecos, dir, shell | …dir, shell, gecos |
| `O_CREAT O_TRUNC O_APPEND O_CLOEXEC` | 0x40 0x200 0x400 0x80000 | 0x200 0x400 0x800 0x40 |
| `F_GETFD F_SETFD` | 1 2 | 2 4 (1 is `F_DUPFD`) |
| wait status | code << 8, signal low | code low, signal << 8 |
| `RTLD_LAZY NOW GLOBAL NODELETE` | 1 2 0x100 0x1000 | 0 1 2 — |

`Haiku/tests/stdlib_check.mojo` uses each of them and checks the answer
against Haiku: 31/31, built by `mojo build` and under `mojo run` alike. The
Linux values would have failed it quietly, not loudly — `time.time()` as the
time since boot, exit code 3 reported as signal 3, `Pipe()` leaking a
duplicated descriptor.

### The CPU

LLVM's `getHostCPUName()` now has a Haiku branch (`354cd02`): each core's
MIDR through `get_cpu_topology_info()`, the table Windows on Arm uses, and
under Apple's hypervisor — part number cleared — `apple-m1`. Measured on
Prose: the compiler targets `apple-m1`, `has_neon_int8_dotprod()` is true and
`has_neon_int8_matmul()` false, as on an M1.

### G6 has begun

`mojo run` works: the JIT runs hello and the check program (31/31, 2.2 s).
Still owed for G6: the stdlib's own CPU test suite on Prose, with a count.

## G6 — The standard library's tests on Prose (2026-09-23)

`tools/haiku/stdlib-tests.py` asks Bazel for the stdlib's 251 `mojo_test`
targets (selects taken as a Haiku build takes them), and
`tools/haiku/run-stdlib-tests.sh` runs them on Prose the way `mojo_test`
does: each file built by the Haiku `mojo` with its flags (`-D ASSERT=all`
by default), run with its environment and arguments, four at a time, each
in its own `TEST_TMPDIR`.

**191 pass, 4 fail, 56 skipped** (the third run, on the image with Haiku
patches 0133 and 0134):

| | tests | why |
|---|---|---|
| skipped | 35 | `python/`: Prose has no Python |
| | 10 | need numpy |
| | 3 | need `//max:max_mojo` (MAX is out of scope) |
| | 1 | GPU |
| | 6 | Bazel would not run them here either: Linux- or macOS-only, or GPU codegen with a compiler built from source |
| | 1 | its source is generated (`test_mojo_version`) |
| failed | 2 | `testing/test_assertion`, `os/test_stat`: use Python at run time (`Python.import_module`) and abort without libpython |
| | 2 | `collections/test_span_{bounds,uninit}_abort`: 2 of 5 cases each time out, see below; run directly, the same aborts behave |

Of the 195 tests that can run on Prose, 191 pass.

### What it took

- **Haiku patch 0133**: `posix_spawn()` ran `argv[0]`, not its path, so
  Mojo's `Process.run("/dir/tool", …)` — and `assert_aborts`, which re-runs
  the test binary — failed with ENOENT. **0134**: a spawn whose exec failed
  wrote the parent's buffered output again (Haiku's `_exit()` flushes, and its
  `vfork()` copies). HaikuArmQemu `tools/spawntest` checks both, 7/7.
- **Crashes must end, not wait for a person.** A Mojo abort is a trap, and
  Haiku's debug_server holds a crashed team in an alert nobody answers on an
  unattended machine; `test_assertion` sat for 600 s. The test machine gets
  `~/config/settings/system/debug_server/settings` with `default_action
  kill`: a crash is then `WIFSIGNALED`, which `assert_aborts` needs.
- **The compile cache outgrew the guest's disk** (1 GB image, ~3 MB a
  test): each test keeps it in its own `TEST_TMPDIR`, as under Bazel.
- Haiku branches in four tests' own per-OS code (sys: c_types, dlhandle,
  ffi with Haiku's `strerror()` texts measured on Prose; pwd; link, since
  BFS has no hard links).

### Open

- **The debug_server does not always act.** In a burst of crashes, some
  teams log "entered the debugger" and nothing more: not killed, no alert,
  left suspended until something kills them (the span tests' harness, after
  60 s; `os/test_stat`'s team was still there an hour later, deaf to
  `kill -9`). Later crashes in the same run are killed. Not yet understood.
- ~~The compiler spends most of its time in the kernel on Prose~~ — it
  does not: arm64 Haiku charged user time as kernel time. See "Where the
  compiler's time goes" below.
- ~~On a machine without Python, the stdlib's libpython discovery passes an
  unterminated empty path to `dlopen`~~ -- a compiler bug in empty strings
  made at compile time, fixed; see "The suite again" below.

## G7 — The bridge: P0 runs (2026-09-23)

Dots runs on Prose: see `Haiku/docs/bridge-design.md`, section 16, for
what P0 measured — chiefly that `BRect` and `BPoint` cross C++ calls by
hidden reference (their copy constructors are user-declared), so the C
interface carries mirror structs, and that a Mojo function's address cannot
name a type (a type tag does). Build on Prose:

```
c++ -O2 -Wall -Wextra -shared -fPIC -o libmojobe.so mojobe.cpp -lbe
mojo build -I Haiku/bridge Haiku/examples/dots/dots.mojo -o dots \
    -Xlinker -L. -Xlinker -lmojobe -Xlinker -lbe
```

Owed for P0: `MouseDown`, by hand (the scripted guest delivers no mouse
events to windows). Next: P1, the generator.

## Where the compiler's time goes (2026-09-24)

The "three quarters in the kernel" of G6 was Haiku's arm64 time accounting:
an interrupt or fault from user mode never recorded the entry into the
kernel, so the return charged the user stretch as kernel time (2 s of pure
arithmetic read 0.004 s user). And the profiler could not see on arm64 at
all. Fixed in HaikuArmQemu, patches 0135 (accounting), 0136 (stack traces
for the profilers) and 0137 (syscall stubs' symbol sizes); tests
`tools/cputime` 3/3 and `tools/proftest` 5/5. Then, measured with
`tools/bench/teamstat` and `profile -k`, for `mojo build stdlib_check.mojo`:

| | wall | user | kernel | page faults |
|---|---|---|---|---|
| `-j 1` | 3.8 s | 3.2 s | 0.5 s | 199,000 |
| default (8 threads) | 6.1 s | 5.3 s | 3.0 s | 222,000 |

- **One thread:** the compiler's own work 65% (MLIR uniquing, hash maps,
  KGEN), libroot's malloc ~15%, the kernel 13% (page faults at ~2.7 µs
  each), the TLS descriptor resolver of patch 0132 ~4%.
- **Eight threads are 60% slower than one**, for 2.2 times the CPU.
  `malloc()` and `free()` are in 36% of the samples; libroot malloc's
  mutexes -- `free()`, `malloc()`, and `findpool()`, which a free of another
  thread's block runs, locking each pool it searches -- make 71% of all
  contended-mutex traffic, ~16% of the compile's CPU on their own (the
  kernel lock and unblock calls and the condition-variable wake-ups under
  them). Page faults 7.5%, the address-space lock ~5%; LLVM's pass
  registry and MLIR's uniquer take the other contended locks.
- **Memory churn:** the heap is returned to the kernel and faulted back
  ~21,000 times a compile (11,855 unmaps, 9,247 resizes); libroot's
  PagesAllocator unmaps from the middle of its areas, which splits them:
  2,414 "heap area" areas at once, most of them 4-32 KB.

Upstream links tcmalloc into the compiler on Linux; here it was aliased
away (G4). The compiler wants a scalable allocator, or libroot's needs to
scale. Until then `-j 1` is the faster setting on Prose.

## The suite again, on Prose with its new allocator (2026-09-24)

Prose now has HaikuArmQemu patches 0138-0140 -- libroot's malloc with
per-thread caches, a page owner map and one overcommitting heap (see its
`docs/malloc.md`) -- and 0141-0150 from a static analysis of the system.
On that image (8 vCPUs), with the compiler of G6:

`mojo build stdlib_check.mojo`, cold cache, measured with `teamstat`:

| | before 0138 | now |
|---|---|---|
| `-j 1` | 3.8 s, 199,000 page faults, 0.5 s kernel | 3.0 s, ~73,000 faults, 0.2 s kernel |
| default (8 threads) | 6.1 s, 222,000 page faults, 3.0 s kernel | 3.7 s, ~109,000 faults, 1.3 s kernel |
| heap areas | ~2,400 | 37 (8 threads: 44) |
| warm cache | 0.8 s | 0.6 s |
| `mojo precompile std` | 14.7 s | 14.0 s |

Eight threads are still slower than one, by 25% rather than 60%. The rest is
not the allocator: LLVM's pass registry and MLIR's uniquer, Haiku's
`pthread_rwlock` (its readers serialise), the kernel's user-mutex
bookkeeping, the TLS resolver and Mojo's clock polling (the profile is in
HaikuArmQemu's `docs/malloc.md`). `-j 1` is still the faster setting.

The standard library's suite: **193 pass, 2 fail, 56 skipped**, in 511 s
with four at a time. The same 191 tests that passed before took 3,248 s of
build and run time then and 1,971 s now (39% less).

- The span tests' aborts pass now: in this run and the next, every crash of
  a burst was killed by the debug_server. Whether the burst problem of G6
  is gone or simply did not happen twice is not proven.
- The 2 failures need Python (`testing/test_assertion`, `os/test_stat`).

### An empty string made at compile time had no terminator

`test_assertion` aborts without Python, as it should, but the runtime
loader logged what it had been asked to open: a file named " is out of
bounds, valid range is 0 to ". `MOJO_PYTHON_LIBRARY` is unset, so
`getenv()` returned its default -- the literal `""`, made at compile time --
and `dlopen()` read the bytes of the next constant.

A probe on Prose: `String("")` built at run time is an empty C string, but
`getenv()` of an unset variable was a 7-byte one, starting at "Runtime". In
the LLVM IR the compiler emits two empty strings: `[1 x i8]
zeroinitializer`, and `[0 x i8]`, which occupies nothing -- the next global
lies at its address -- while `String` flags it as nul terminated. Five of
the six places that turn a string into interpreter memory special-cased ""
with `str = "\0"`: StringRef's C-string constructor, so `strlen("\0")`,
no bytes. The sixth wrote `StringRef("\0", 1)`. Fixed, with a test in
`test_string`: a default argument of `""` as a C string, which fails with
the old compiler and passes now; the suite is unchanged by the fix. Nothing
here is Haiku's: every target has this.

## G7 — The bridge: P1, generated (2026-09-24)

The bridge is generated now. `Haiku/generator/mojobe_gen.py` reads the
Haiku headers through the build's clang (its JSON AST, for
`aarch64-unknown-haiku`) and the annotations in `bridge.toml`, and writes
both halves from one model: `libmojobe`'s entry points and shadow classes,
and the `haiku` package's modules, with a manifest of every method and why
any is left out. Constants and value-type layouts come from clang too: a
probe file of `extern "C"` globals compiled to LLVM IR. For P0's seven
classes: 641 methods, 379 left out (three quarters for a type not yet
bridged), 916 constants, in about 4 s.

The output replaces P0's hand-written bridge, and Dots still runs:
`Haiku/tests/dots_smoke.py`, 5/5, against a headless Prose machine
(captures, `hey`, exit status). `Haiku/tests/bridge_check.mojo`, 28/28,
checks the rest against `libbe`: constants, value types by value and as
results, `status_t` raising with `strerror()`'s text, out-parameters as
results and tuples, NULL references, adoption, by-value overloads.
`libmojobe.so` builds warning-clean with `-Wall -Wextra -Wpointer-arith`
both with Prose's clang and on the Mac with the build's clang and `ld.lld`.

What it settled, measured, is in `Haiku/docs/bridge-design.md` §17: every
value type as a C mirror struct; named enums as Mojo types (else BWindow's
two constructors collide); overloads a call cannot tell apart left out;
and one hazard the tests found — a reference got from an owned value does
not keep it alive, and Mojo's ASAP destruction deleted a parent view under
its child's reference. That is the design's first open question, for P2.

Build and test (the guest runner is any command that runs a shell line on
the machine and prints the output):

```
python3 Haiku/generator/mojobe_gen.py          # on the Mac; CLANG=… if needed
# on Prose, in a directory holding Haiku/bridge/{libmojobe,haiku}:
c++ -O2 -Wall -Wextra -Wpointer-arith -shared -fPIC -o libmojobe.so \
    libmojobe/mojobe.cpp -lbe
mojo build -I . dots.mojo -o dots -Xlinker -L. -Xlinker -lmojobe -Xlinker -lbe
# on the Mac, with the machine running and automation allowed:
python3 Haiku/tests/dots_smoke.py --run RUNNER --app …/Prose.app --dir DIR
```

## G7 — The bridge: P2, first half (2026-09-24)

P2 is "the v1 scope, the ABI oracle, the tests". Done so far, each step with
its tests (bridge-design.md §18 has the measured detail):

- **References carry origins.** `BViewRef[origin]` keeps alive what it was
  got from and cannot outlive it; a hook's references are borrowed from its
  call. This fixes P1's measured hazard (Mojo ending a parent view under its
  child's reference), and the compiler refuses keeping a hook's reference,
  returning one past its owner, or using one after `window^.Show()`.
- **BHandler, BLooper; BMessenger and `Locked`.** A new kind of class, held
  in a Mojo value (BMessenger); `with messenger.Locked() as looper:` from any
  thread; checked downcasts (`as_BWindow()`).
- **Errors name their status** (`… (B_NAME_NOT_FOUND)`, `status_of(e)`);
  typed raises were measured and set aside (a `try` block's error type is
  fixed by its first call).
- **No C++ exception reaches Mojo**, and an adoption that fails no longer
  leaks.
- **The ABI oracle**, generated: every hook through the real trampolines,
  value types and enums both ways, a call on the stack; two mutants show it
  failing.

On Prose, `Haiku/tests/run.sh`: abi_oracle 87/87, bridge_check 38/38,
threads_check 16/16 (all three also under the guarded heap),
must_not_compile 5/5; `dots_smoke.py` 5/5. Found and fixed on the way: a
shadow constructor taking any argument as its Mojo state (`BLooper("x")`),
owned upcasts from self-owning classes, hand-over methods counted as
inherited, and `[inout]` leaving out by-value twins.

Next in P2: the rest of the v1 classes (§13) — controls and alerts, fonts,
bitmaps, screens and regions, message runners, the storage kit's paths and
file panels, layouts, list and scroll views.
