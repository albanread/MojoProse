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
