# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #

from std.ffi import CStringSpan, c_int, external_call
from std.sys.info import CompilationTarget, platform_map


def _errno_ptr(out result: Pointer[c_int, MutUntrackedOrigin]):
    comptime if CompilationTarget.is_linux():
        result = external_call["__errno_location", type_of(result)]()
    elif CompilationTarget.is_macos():
        result = external_call["__error", type_of(result)]()
    elif CompilationTarget.is_haiku():
        result = external_call["_errnop", type_of(result)]()
    else:
        CompilationTarget.unsupported_target_error[operation="get_errno"]()


def get_errno() -> ErrNo:
    """Gets the current value of the libc errno.

    This function retrieves the thread-local errno value set by the last
    failed system call. The implementation is platform-specific, using
    `__errno_location()` on Linux, `__error()` on macOS and `_errnop()` on
    Haiku.

    Returns:
        The current errno value as an ErrNo struct.

    Constrained:
        Compilation error on unsupported platforms.
    """
    return ErrNo(_errno_ptr()[])


def set_errno(errno: ErrNo):
    """Sets the C library errno to a specific value.

    This function sets the thread-local errno value. It's typically used to
    clear errno before making a system call to detect errors reliably.

    Args:
        errno: The errno value to set.

    Constrained:
        Compilation error on unsupported platforms.
    """
    _errno_ptr()[] = errno.value


# Alias to shorten the error definitions below
comptime pm = platform_map[T=Int, ...]


@fieldwise_init
struct ErrNo(Equatable, TrivialRegisterPassable, Writable):
    """Represents a error number from libc.

    This struct acts as an enum providing a wrapper around C library error codes,
    with platform-specific values for error constants.

    Example:
        ```mojo
        from std.os import abort
        from std.sys._libc_errno import get_errno, set_errno, ErrNo

        def main():
            var err = get_errno()
            if err == ErrNo.ENOENT:
                # Handle missing path, clear errno, and continue
                set_errno(ErrNo.SUCCESS)
            elif err != ErrNo.SUCCESS:
                # Else abort on error
                abort("unexpected errno")
        ```
    """

    var value: c_int
    """The numeric error code value."""

    # fmt: off
    comptime SUCCESS        = Self(0)
    """Success."""
    comptime EPERM          = Self(pm["EPERM",            linux=1, macos=1, haiku=-2147483633]())
    """Operation not permitted."""
    comptime ENOENT         = Self(pm["ENOENT",           linux=2, macos=2, haiku=-2147459069]())
    """No such file or directory."""
    comptime ESRCH          = Self(pm["ESRCH",            linux=3, macos=3, haiku=-2147454963]())
    """No such process."""
    comptime EINTR          = Self(pm["EINTR",            linux=4, macos=4, haiku=-2147483638]())
    """Interrupted system call."""
    comptime EIO            = Self(pm["EIO",              linux=5, macos=5, haiku=-2147483647]())
    """I/O error."""
    comptime ENXIO          = Self(pm["ENXIO",            linux=6, macos=6, haiku=-2147454965]())
    """No such device or address."""
    comptime E2BIG          = Self(pm["E2BIG",            linux=7, macos=7, haiku=-2147454975]())
    """Argument list too long."""
    comptime ENOEXEC        = Self(pm["ENOEXEC",          linux=8, macos=8, haiku=-2147478782]())
    """Exec format error."""
    comptime EBADF          = Self(pm["EBADF",            linux=9, macos=9, haiku=-2147459072]())
    """Bad file number."""
    comptime ECHILD         = Self(pm["ECHILD",           linux=10, macos=10, haiku=-2147454974]())
    """No child processes."""
    comptime EAGAIN         = Self(pm["EAGAIN",           linux=11, macos=35, haiku=-2147483637]())
    """Try again."""
    comptime ENOMEM         = Self(pm["ENOMEM",           linux=12, macos=12, haiku=-2147483648]())
    """Out of memory."""
    comptime EACCES         = Self(pm["EACCES",           linux=13, macos=13, haiku=-2147483646]())
    """Permission denied."""
    comptime EFAULT         = Self(pm["EFAULT",           linux=14, macos=14, haiku=-2147478783]())
    """Bad address."""
    comptime ENOTBLK        = Self(pm["ENOTBLK",          linux=15, macos=15]())
    """Block device required."""
    comptime EBUSY          = Self(pm["EBUSY",            linux=16, macos=16, haiku=-2147483634]())
    """Device or resource busy."""
    comptime EEXIST         = Self(pm["EEXIST",           linux=17, macos=17, haiku=-2147459070]())
    """File exists."""
    comptime EXDEV          = Self(pm["EXDEV",            linux=18, macos=18, haiku=-2147459061]())
    """Cross-device link."""
    comptime ENODEV         = Self(pm["ENODEV",           linux=19, macos=19, haiku=-2147454969]())
    """No such device."""
    comptime ENOTDIR        = Self(pm["ENOTDIR",          linux=20, macos=20, haiku=-2147459067]())
    """Not a directory."""
    comptime EISDIR         = Self(pm["EISDIR",           linux=21, macos=21, haiku=-2147459063]())
    """Is a directory."""
    comptime EINVAL         = Self(pm["EINVAL",           linux=22, macos=22, haiku=-2147483643]())
    """Invalid argument."""
    comptime ENFILE         = Self(pm["ENFILE",           linux=23, macos=23, haiku=-2147454970]())
    """File table overflow."""
    comptime EMFILE         = Self(pm["EMFILE",           linux=24, macos=24, haiku=-2147459062]())
    """Too many open files."""
    comptime ENOTTY         = Self(pm["ENOTTY",           linux=25, macos=25, haiku=-2147454966]())
    """Not a typewriter."""
    comptime ETXTBSY        = Self(pm["ETXTBSY",          linux=26, macos=26, haiku=-2147454917]())
    """Text file busy."""
    comptime EFBIG          = Self(pm["EFBIG",            linux=27, macos=27, haiku=-2147454972]())
    """File too large."""
    comptime ENOSPC         = Self(pm["ENOSPC",           linux=28, macos=28, haiku=-2147459065]())
    """No space left on device."""
    comptime ESPIPE         = Self(pm["ESPIPE",           linux=29, macos=29, haiku=-2147454964]())
    """Illegal seek."""
    comptime EROFS          = Self(pm["EROFS",            linux=30, macos=30, haiku=-2147459064]())
    """Read-only file system."""
    comptime EMLINK         = Self(pm["EMLINK",           linux=31, macos=31, haiku=-2147454971]())
    """Too many links."""
    comptime EPIPE          = Self(pm["EPIPE",            linux=32, macos=32, haiku=-2147459059]())
    """Broken pipe."""
    comptime EDOM           = Self(pm["EDOM",             linux=33, macos=33, haiku=-2147454960]())
    """Math argument out of domain of func."""
    comptime ERANGE         = Self(pm["ERANGE",           linux=34, macos=34, haiku=-2147454959]())
    """Math result not representable."""
    comptime EDEADLK        = Self(pm["EDEADLK",          linux=35, macos=11, haiku=-2147454973]())
    """Resource deadlock would occur."""
    comptime ENAMETOOLONG   = Self(pm["ENAMETOOLONG",     linux=36, macos=63, haiku=-2147459068]())
    """File name too long."""
    comptime ENOLCK         = Self(pm["ENOLCK",           linux=37, macos=77, haiku=-2147454968]())
    """No record locks available."""
    comptime ENOSYS         = Self(pm["ENOSYS",           linux=38, macos=78, haiku=-2147454967]())
    """Function not implemented."""
    comptime ENOTEMPTY      = Self(pm["ENOTEMPTY",        linux=39, macos=66, haiku=-2147459066]())
    """Directory not empty."""
    comptime ELOOP          = Self(pm["ELOOP",            linux=40, macos=62, haiku=-2147459060]())
    """Too many symbolic links encountered."""
    comptime EWOULDBLOCK    = Self.EAGAIN
    """Operation would block."""
    comptime ENOMSG         = Self(pm["ENOMSG",           linux=42, macos=91, haiku=-2147454937]())
    """No message of desired type."""
    comptime EIDRM          = Self(pm["EIDRM",            linux=43, macos=90, haiku=-2147454926]())
    """Identifier removed."""
    comptime ECHRNG         = Self(pm["ECHRNG",           linux=44]())
    """Channel number out of range."""
    comptime EL2NSYNC       = Self(pm["EL2NSYNC",         linux=45]())
    """Level 2 not synchronized."""
    comptime EL3HLT         = Self(pm["EL3HLT",           linux=46]())
    """Level 3 halted."""
    comptime EL3RST         = Self(pm["EL3RST",           linux=47]())
    """Level 3 reset."""
    comptime ELNRNG         = Self(pm["ELNRNG",           linux=48]())
    """Link number out of range."""
    comptime EUNATCH        = Self(pm["EUNATCH",          linux=49]())
    """Protocol driver not attached."""
    comptime ENOCSI         = Self(pm["ENOCSI",           linux=50]())
    """No CSI structure available."""
    comptime EL2HLT         = Self(pm["EL2HLT",           linux=51]())
    """Level 2 halted."""
    comptime EBADE          = Self(pm["EBADE",            linux=52]())
    """Invalid exchange."""
    comptime EBADR          = Self(pm["EBADR",            linux=53]())
    """Invalid request descriptor."""
    comptime EXFULL         = Self(pm["EXFULL",           linux=54]())
    """Exchange full."""
    comptime ENOANO         = Self(pm["ENOANO",           linux=55]())
    """No anode."""
    comptime EBADRQC        = Self(pm["EBADRQC",          linux=56]())
    """Invalid request code."""
    comptime EBADSLT        = Self(pm["EBADSLT",          linux=57]())
    """Invalid slot."""
    comptime EDEADLOCK      = Self.EDEADLK
    """Alias for EDEADLK."""
    comptime EBFONT         = Self(pm["EBFONT",           linux=59]())
    """Bad font file format."""
    comptime ENOSTR         = Self(pm["ENOSTR",           linux=60, macos=99, haiku=-2147454921]())
    """Device not a stream."""
    comptime ENODATA        = Self(pm["ENODATA",          linux=61, macos=96, haiku=-2147454924]())
    """No data available."""
    comptime ETIME          = Self(pm["ETIME",            linux=62, macos=101, haiku=-2147454918]())
    """Timer expired."""
    comptime ENOSR          = Self(pm["ENOSR",            linux=63, macos=98, haiku=-2147454922]())
    """Out of streams resources."""
    comptime ENONET         = Self(pm["ENONET",           linux=64]())
    """Machine is not on the network."""
    comptime ENOPKG         = Self(pm["ENOPKG",           linux=65]())
    """Package not installed."""
    comptime EREMOTE        = Self(pm["EREMOTE",          linux=66, macos=71]())
    """Object is remote."""
    comptime ENOLINK        = Self(pm["ENOLINK",          linux=67, macos=97, haiku=-2147454923]())
    """Link has been severed."""
    comptime EADV           = Self(pm["EADV",             linux=68]())
    """Advertise error."""
    comptime ESRMNT         = Self(pm["ESRMNT",           linux=69]())
    """Srmount error."""
    comptime ECOMM          = Self(pm["ECOMM",            linux=70]())
    """Communication error on send."""
    comptime EPROTO         = Self(pm["EPROTO",           linux=71, macos=100, haiku=-2147454919]())
    """Protocol error."""
    comptime EMULTIHOP      = Self(pm["EMULTIHOP",        linux=72, macos=95, haiku=-2147454925]())
    """Multihop attempted."""
    comptime EDOTDOT        = Self(pm["EDOTDOT",          linux=73]())
    """RFS specific error."""
    comptime EBADMSG        = Self(pm["EBADMSG",          linux=74, macos=94, haiku=-2147454930]())
    """Not a data message."""
    comptime EOVERFLOW      = Self(pm["EOVERFLOW",        linux=75, macos=84, haiku=-2147454935]())
    """Value too large for defined data type."""
    comptime ENOTUNIQ       = Self(pm["ENOTUNIQ",         linux=76]())
    """Name not unique on network."""
    comptime EBADFD         = Self(pm["EBADFD",           linux=77]())
    """File descriptor in bad state."""
    comptime EREMCHG        = Self(pm["EREMCHG",          linux=78]())
    """Remote address changed."""
    comptime ELIBACC        = Self(pm["ELIBACC",          linux=79]())
    """Can not access a needed shared library."""
    comptime ELIBBAD        = Self(pm["ELIBBAD",          linux=80]())
    """Accessing a corrupted shared library."""
    comptime ELIBSCN        = Self(pm["ELIBSCN",          linux=81]())
    """.lib section in a.out corrupted."""
    comptime ELIBMAX        = Self(pm["ELIBMAX",          linux=82]())
    """Attempting to link in too many shared libraries."""
    comptime ELIBEXEC       = Self(pm["ELIBEXEC",         linux=83]())
    """Cannot exec a shared library directly."""
    comptime EILSEQ         = Self(pm["EILSEQ",           linux=84, macos=92, haiku=-2147454938]())
    """Illegal byte sequence."""
    comptime ERESTART       = Self(pm["ERESTART",         linux=85]())
    """Interrupted system call should be restarted."""
    comptime ESTRPIPE       = Self(pm["ESTRPIPE",         linux=86]())
    """Streams pipe error."""
    comptime EUSERS         = Self(pm["EUSERS",           linux=87, macos=68]())
    """Too many users."""
    comptime ENOTSOCK       = Self(pm["ENOTSOCK",         linux=88, macos=38, haiku=-2147454932]())
    """Socket operation on non-socket."""
    comptime EDESTADDRREQ   = Self(pm["EDESTADDRREQ",     linux=89, macos=39, haiku=-2147454928]())
    """Destination address required."""
    comptime EMSGSIZE       = Self(pm["EMSGSIZE",         linux=90, macos=40, haiku=-2147454934]())
    """Message too long."""
    comptime EPROTOTYPE     = Self(pm["EPROTOTYPE",       linux=91, macos=41, haiku=-2147454958]())
    """Protocol wrong type for socket."""
    comptime ENOPROTOOPT    = Self(pm["ENOPROTOOPT",      linux=92, macos=42, haiku=-2147454942]())
    """Protocol not available."""
    comptime EPROTONOSUPPORT= Self(pm["EPROTONOSUPPORT",  linux=93, macos=43, haiku=-2147454957]())
    """Protocol not supported."""
    comptime ESOCKTNOSUPPORT= Self(pm["ESOCKTNOSUPPORT",  linux=94, macos=44, haiku=-2147454913]())
    """Socket type not supported."""
    comptime EOPNOTSUPP     = Self(pm["EOPNOTSUPP",       linux=95, macos=102, haiku=-2147454933]())
    """Operation not supported on transport endpoint."""
    comptime EPFNOSUPPORT   = Self(pm["EPFNOSUPPORT",     linux=96, macos=46, haiku=-2147454956]())
    """Protocol family not supported."""
    comptime EAFNOSUPPORT   = Self(pm["EAFNOSUPPORT",     linux=97, macos=47, haiku=-2147454955]())
    """Address family not supported by protocol."""
    comptime EADDRINUSE     = Self(pm["EADDRINUSE",       linux=98, macos=48, haiku=-2147454954]())
    """Address already in use."""
    comptime EADDRNOTAVAIL  = Self(pm["EADDRNOTAVAIL",    linux=99, macos=49, haiku=-2147454953]())
    """Cannot assign requested address."""
    comptime ENETDOWN       = Self(pm["ENETDOWN",         linux=100, macos=50, haiku=-2147454952]())
    """Network is down."""
    comptime ENETUNREACH    = Self(pm["ENETUNREACH",      linux=101, macos=51, haiku=-2147454951]())
    """Network is unreachable."""
    comptime ENETRESET      = Self(pm["ENETRESET",        linux=102, macos=52, haiku=-2147454950]())
    """Network dropped connection because of reset."""
    comptime ECONNABORTED   = Self(pm["ECONNABORTED",     linux=103, macos=53, haiku=-2147454949]())
    """Software caused connection abort."""
    comptime ECONNRESET     = Self(pm["ECONNRESET",       linux=104, macos=54, haiku=-2147454948]())
    """Connection reset by peer."""
    comptime ENOBUFS        = Self(pm["ENOBUFS",          linux=105, macos=55, haiku=-2147454941]())
    """No buffer space available."""
    comptime EISCONN        = Self(pm["EISCONN",          linux=106, macos=56, haiku=-2147454947]())
    """Transport endpoint is already connected."""
    comptime ENOTCONN       = Self(pm["ENOTCONN",         linux=107, macos=57, haiku=-2147454946]())
    """Transport endpoint is not connected."""
    comptime ESHUTDOWN      = Self(pm["ESHUTDOWN",        linux=108, macos=58, haiku=-2147454945]())
    """Cannot send after transport endpoint shutdown."""
    comptime ETOOMANYREFS   = Self(pm["ETOOMANYREFS",     linux=109, macos=59]())
    """Too many references: cannot splice."""
    comptime ETIMEDOUT      = Self(pm["ETIMEDOUT",        linux=110, macos=60, haiku=-2147483639]())
    """Connection timed out."""
    comptime ECONNREFUSED   = Self(pm["ECONNREFUSED",     linux=111, macos=61, haiku=-2147454944]())
    """Connection refused."""
    comptime EHOSTDOWN      = Self(pm["EHOSTDOWN",        linux=112, macos=64, haiku=-2147454931]())
    """Host is down."""
    comptime EHOSTUNREACH   = Self(pm["EHOSTUNREACH",     linux=113, macos=65, haiku=-2147454943]())
    """No route to host."""
    comptime EALREADY       = Self(pm["EALREADY",         linux=114, macos=37, haiku=-2147454939]())
    """Operation already in progress."""
    comptime EINPROGRESS    = Self(pm["EINPROGRESS",      linux=115, macos=36, haiku=-2147454940]())
    """Operation now in progress."""
    comptime ESTALE         = Self(pm["ESTALE",           linux=116, macos=70, haiku=-2147454936]())
    """Stale NFS file handle."""
    comptime EUCLEAN        = Self(pm["EUCLEAN",          linux=117]())
    """Structure needs cleaning."""
    comptime ENOTNAM        = Self(pm["ENOTNAM",          linux=118]())
    """Not a XENIX named type file."""
    comptime ENAVAIL        = Self(pm["ENAVAIL",          linux=119]())
    """No XENIX semaphores available."""
    comptime EISNAM         = Self(pm["EISNAM",           linux=120]())
    """Is a named type file."""
    comptime EREMOTEIO      = Self(pm["EREMOTEIO",        linux=121]())
    """Remote I/O error."""
    comptime EDQUOT         = Self(pm["EDQUOT",           linux=122, macos=69, haiku=-2147454927]())
    """Quota exceeded."""
    comptime ENOMEDIUM      = Self(pm["ENOMEDIUM",        linux=123]())
    """No medium found."""
    comptime EMEDIUMTYPE    = Self(pm["EMEDIUMTYPE",      linux=124]())
    """Wrong medium type."""
    comptime ECANCELED      = Self(pm["ECANCELED",        linux=125, macos=89, haiku=-2147454929]())
    """Operation canceled."""
    comptime ENOKEY         = Self(pm["ENOKEY",           linux=126]())
    """Required key not available."""
    comptime EKEYEXPIRED    = Self(pm["EKEYEXPIRED",      linux=127]())
    """Key has expired."""
    comptime EKEYREVOKED    = Self(pm["EKEYREVOKED",      linux=128]())
    """Key has been revoked."""
    comptime EKEYREJECTED   = Self(pm["EKEYREJECTED",     linux=129]())
    """Key was rejected by service."""
    comptime EOWNERDEAD     = Self(pm["EOWNERDEAD",       linux=130, macos=105, haiku=-2147454914]())
    """Owner died."""
    comptime ENOTRECOVERABLE= Self(pm["ENOTRECOVERABLE",  linux=131, macos=104, haiku=-2147454915]())
    """State not recoverable."""
    comptime ERFKILL        = Self(pm["ERFKILL",          linux=132]())
    """Operation not possible due to RF-kill."""
    comptime EHWPOISON      = Self(pm["EHWPOISON",        linux=133]())
    """Memory page has hardware error."""


    # macOS-specific
    comptime ENOTSUP        = Self(pm["ENOTSUP",          macos=45, haiku=-2147454920]())
    """Operation not supported."""
    comptime EPROCLIM       = Self(pm["EPROCLIM",         macos=67]())
    """Too many processes."""
    comptime EBADRPC        = Self(pm["EBADRPC",          macos=72]())
    """RPC struct is bad."""
    comptime ERPCMISMATCH   = Self(pm["ERPCMISMATCH",     macos=73]())
    """RPC version wrong."""
    comptime EPROGUNAVAIL   = Self(pm["EPROGUNAVAIL",     macos=74]())
    """RPC prog. not avail."""
    comptime EPROGMISMATCH  = Self(pm["EPROGMISMATCH",    macos=75]())
    """Program version wrong."""
    comptime EPROCUNAVAIL   = Self(pm["EPROCUNAVAIL",     macos=76]())
    """Bad procedure for program."""
    comptime EFTYPE         = Self(pm["EFTYPE",           macos=79]())
    """Inappropriate file type or format."""
    comptime EAUTH          = Self(pm["EAUTH",            macos=80]())
    """Authentication error."""
    comptime ENEEDAUTH      = Self(pm["ENEEDAUTH",        macos=81]())
    """Need authenticator."""
    comptime EPWROFF        = Self(pm["EPWROFF",          macos=82]())
    """Device power is off."""
    comptime EDEVERR        = Self(pm["EDEVERR",          macos=83]())
    """Device error, e.g. paper out."""
    comptime EBADEXEC       = Self(pm["EBADEXEC",         macos=85]())
    """Bad executable."""
    comptime EBADARCH       = Self(pm["EBADARCH",         macos=86]())
    """Bad CPU type in executable."""
    comptime ESHLIBVERS     = Self(pm["ESHLIBVERS",       macos=87]())
    """Shared library version mismatch."""
    comptime EBADMACHO      = Self(pm["EBADMACHO",        macos=88]())
    """Malformed Macho file."""
    comptime ENOATTR        = Self(pm["ENOATTR",          macos=93, haiku=-2147454916]())
    """Attribute not found."""
    comptime ENOPOLICY      = Self(pm["ENOPOLICY",        macos=103]())
    """No such policy registered."""
    comptime EQFULL         = Self(pm["EQFULL",           macos=106]())
    """Interface output queue is full."""
    # fmt: on

    def __init__(out self, value: Int):
        """Constructs an ErrNo from an integer value.

        Args:
            value: The numeric error code.
        """
        # Haiku's error codes are negative: its errno values are the
        # system's status codes, which count up from INT_MIN.
        comptime lowest = Int(
            c_int.MIN
        ) if CompilationTarget.is_haiku() else 0
        assert (
            lowest <= value <= Int(c_int.MAX)
        ), "constructed ErrNo from an `Int` out of range of `c_int`"
        self.value = c_int(value)

    def write_to(self, mut writer: Some[Writer]):
        """Writes the human-readable error description to a writer.

        Args:
            writer: The writer to write the error description to.
        """

        comptime if CompilationTarget.is_macos():
            assert self != ErrNo.SUCCESS, "macos can't stringify ErrNo.SUCCESS"
        var ptr = external_call["strerror", Pointer[Byte, MutUntrackedOrigin]](
            self.value
        )
        var string = StringSlice(
            unsafe_from_utf8=CStringSpan(
                unsafe_from_ptr=ptr.unsafe_bitcast[Int8]().unsafe_mut_cast[
                    False
                ]()
            )
        )
        string.write_to(writer)

    @inline(.always)
    def __eq__(self, other: Self) -> Bool:
        """Checks if two `ErrNo` values are equal.

        Args:
            other: The `ErrNo` value to compare with.

        Returns:
            True if the error codes are equal, False otherwise.
        """
        return self.value == other.value

    @inline(.always)
    def __ne__(self, other: Self) -> Bool:
        """Checks if two `ErrNo` values are not equal.

        Args:
            other: The `ErrNo` value to compare with.

        Returns:
            True if the error codes are not equal, False otherwise.
        """
        return self.value != other.value
