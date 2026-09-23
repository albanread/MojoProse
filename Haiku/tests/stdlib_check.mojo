# Checks the standard library's Haiku support on Prose: each part that has a
# Haiku branch is used, and its result compared with what Haiku says.

from std.ffi import OwnedDLHandle, c_int
from std.os import getenv, getuid, listdir, mkdir, remove, rmdir, setenv, stat
from std.os.path import exists, expanduser, isdir, isfile
from std.os.process import Pipe, Process
from std.pwd import getpwuid
from std.stat import S_ISDIR, S_ISREG
from std.sys import CompilationTarget
from std.sys._libc import fcntl
from std.sys._libc_errno import ErrNo, get_errno, set_errno
from std.time import perf_counter_ns, sleep
from std.time.time import _realtime_nanoseconds


struct Checks:
    var passed: Int
    var failed: Int

    def __init__(out self):
        self.passed = 0
        self.failed = 0

    def check(mut self, ok: Bool, name: String, detail: String = ""):
        if ok:
            self.passed += 1
            print("PASS", name)
        else:
            self.failed += 1
            print("FAIL", name, detail)


def main() raises:
    var c = Checks()

    # The target.
    c.check(CompilationTarget.is_haiku(), "target is Haiku")
    c.check(not CompilationTarget.is_linux(), "target is not Linux")

    # errno: Haiku's codes are negative, read through _errnop().
    set_errno(ErrNo.EINTR)
    c.check(get_errno() == ErrNo.EINTR, "set_errno/get_errno round trip")
    c.check(Int(ErrNo.ENOENT.value) == -2147459069, "ENOENT is Haiku's")
    try:
        _ = stat("/no/such/path")
        c.check(False, "stat of a missing path raises")
    except:
        c.check(True, "stat of a missing path raises")
        var err = get_errno()
        c.check(err == ErrNo.ENOENT, "missing path sets ENOENT", String(err))
    c.check(
        String(ErrNo.ENOENT) == "No such file or directory",
        "strerror(ENOENT)",
        String(ErrNo.ENOENT),
    )

    # Files: O_CREAT|O_TRUNC, then O_APPEND, then truncation again.
    var dir = String("/boot/home/mojo/check.tmp")
    if exists(dir):
        for name in listdir(dir):
            remove(dir + "/" + name)
        rmdir(dir)
    mkdir(dir)
    c.check(isdir(dir), "mkdir makes a directory")
    var path = dir + "/a"
    with open(path, "w") as f:
        f.write("hello")
    with open(path, "a") as f:
        f.write(" world")
    with open(path, "r") as f:
        var text = f.read()
        c.check(text == "hello world", "write then append", text)
    with open(path, "w") as f:
        f.write("x")
    with open(path, "r") as f:
        var text = f.read()
        c.check(text == "x", "reopening for writing truncates", text)

    # stat: Haiku's struct stat, 128 bytes, st_mode at 16.
    var s = stat(path)
    c.check(s.st_size == 1, "st_size", String(s.st_size))
    c.check(S_ISREG(s.st_mode), "st_mode says regular file", String(s.st_mode))
    c.check(s.st_ino != 0, "st_ino", String(s.st_ino))
    c.check(S_ISDIR(stat(dir).st_mode), "st_mode says directory")
    c.check(isfile(path) and not isfile(dir), "isfile")

    # The real-time clock, against the file system's idea of now.
    var now = _realtime_nanoseconds()
    var mtime = s.st_mtimespec.as_nanoseconds()
    var skew = now - mtime
    c.check(
        skew >= 0 and skew < 10_000_000_000,
        "CLOCK_REALTIME agrees with a new file's mtime",
        String(skew),
    )

    # The monotonic clock.
    var t0 = perf_counter_ns()
    sleep(0.05)
    var elapsed = perf_counter_ns() - t0
    c.check(
        elapsed >= 50_000_000 and elapsed < 1_000_000_000,
        "sleep(0.05) by the monotonic clock",
        String(elapsed),
    )

    # Directories: Haiku's dirent, the name at offset 26.
    for name in ["b", "c"]:
        with open(dir + "/" + name, "w") as f:
            f.write(name)
    var names = listdir(dir)
    sort(names)
    c.check(
        len(names) == 3
        and names[0] == "a"
        and names[1] == "b"
        and names[2] == "c",
        "listdir",
        String(len(names)),
    )

    # passwd: Haiku puts pw_dir and pw_shell before pw_gecos.
    var pw = getpwuid(getuid())
    c.check(pw.pw_dir == "/boot/home", "getpwuid home", pw.pw_dir)
    c.check(pw.pw_shell.endswith("sh"), "getpwuid shell", pw.pw_shell)
    c.check(pw.pw_name.byte_length() > 0, "getpwuid name", pw.pw_name)
    c.check(expanduser("~") == "/boot/home", "expanduser", expanduser("~"))

    # The environment.
    c.check(getenv("HOME") == "/boot/home", "getenv HOME", getenv("HOME"))
    _ = setenv("MOJO_HAIKU_CHECK", "42")
    c.check(getenv("MOJO_HAIKU_CHECK") == "42", "setenv")

    # Processes: Haiku's wait status keeps the exit code in the low byte.
    var p = Process.run("/bin/sh", ["-c", "exit 3"])
    var status = p.wait()
    c.check(
        status.exit_code and status.exit_code.value() == 3,
        "exit code 3 is 3",
    )
    var q = Process.run("/bin/sh", ["-c", "kill -9 $$"])
    var qs = q.wait()
    c.check(
        qs.term_signal and qs.term_signal.value() == 9,
        "a SIGKILLed child reports signal 9",
    )
    try:
        _ = Process.run("/no/such/program", [])
        c.check(False, "spawning a missing program raises")
    except:
        c.check(True, "spawning a missing program raises")

    # Pipes set FD_CLOEXEC with fcntl, whose commands are bits on Haiku:
    # F_GETFD is 2 there, and 1 would be F_DUPFD.
    var pipe = Pipe()
    var fd = c_int(pipe.fd_in.value().value)
    var flags = fcntl(fd, c_int(2), 0)
    c.check(flags & 1 == 1, "Pipe sets FD_CLOEXEC", String(flags))
    pipe.write_bytes("ping".as_bytes())

    # dlopen: Haiku's RTLD_NOW|RTLD_GLOBAL is 3.
    var libroot = OwnedDLHandle("libroot.so")
    c.check(libroot.check_symbol("getpid"), "dlopen libroot, find getpid")
    var this = OwnedDLHandle()
    c.check(this.check_symbol("printf"), "dlopen(NULL) finds printf")

    for name in listdir(dir):
        remove(dir + "/" + name)
    rmdir(dir)
    c.check(not exists(dir), "cleanup")

    print(
        "SELFTEST",
        "PASS" if c.failed == 0 else "FAIL",
        String(c.passed) + "/" + String(c.passed + c.failed),
    )
