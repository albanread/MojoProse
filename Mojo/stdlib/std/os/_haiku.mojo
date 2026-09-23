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
"""Haiku's `struct stat`, as its <sys/stat.h> declares it on 64-bit
targets.

The offsets in the comments were measured against Haiku's headers with the
toolchain the compiler is built with.
"""

from std.ffi import external_call
from std.time.time import _CTimeSpec

from .fstat import stat_result

comptime dev_t = Int32
comptime ino_t = Int64
comptime mode_t = UInt32
comptime nlink_t = Int32
comptime uid_t = UInt32
comptime gid_t = UInt32
comptime off_t = Int64
comptime blksize_t = Int32
comptime blkcnt_t = Int64


struct _c_stat(Copyable, Defaultable, Writable):
    var st_dev: dev_t
    """ID of the device the file resides on (offset 0)."""
    var __pad0: Int32
    """Padding."""
    var st_ino: ino_t
    """The file's inode number (offset 8)."""
    var st_mode: mode_t
    """Mode of file (offset 16)."""
    var st_nlink: nlink_t
    """Number of hard links (offset 20)."""
    var st_uid: uid_t
    """User ID of the file (offset 24)."""
    var st_gid: gid_t
    """Group ID of the file (offset 28)."""
    var st_size: off_t
    """File size, in bytes (offset 32)."""
    var st_rdev: dev_t
    """Device type, unused (offset 40)."""
    var st_blksize: blksize_t
    """Preferred block size for I/O (offset 44)."""
    var st_atimespec: _CTimeSpec
    """Time of last access (st_atim, offset 48)."""
    var st_mtimespec: _CTimeSpec
    """Time of last data modification (st_mtim, offset 64)."""
    var st_ctimespec: _CTimeSpec
    """Time of last status change (st_ctim, offset 80)."""
    var st_birthtimespec: _CTimeSpec
    """Time of file creation (st_crtim, offset 96)."""
    var st_type: UInt32
    """Attribute or index type (offset 112)."""
    var __pad1: Int32
    """Padding."""
    var st_blocks: blkcnt_t
    """Blocks allocated for file (offset 120; the struct is 128 bytes)."""

    def __init__(out self):
        self.st_dev = 0
        self.__pad0 = 0
        self.st_ino = 0
        self.st_mode = 0
        self.st_nlink = 0
        self.st_uid = 0
        self.st_gid = 0
        self.st_size = 0
        self.st_rdev = 0
        self.st_blksize = 0
        self.st_atimespec = _CTimeSpec()
        self.st_mtimespec = _CTimeSpec()
        self.st_ctimespec = _CTimeSpec()
        self.st_birthtimespec = _CTimeSpec()
        self.st_type = 0
        self.__pad1 = 0
        self.st_blocks = 0

    def write_to(self, mut writer: Some[Writer]):
        # fmt: off
        writer.write(
            "{\nst_dev: ", self.st_dev,
            ",\nst_mode: ", self.st_mode,
            ",\nst_nlink: ", self.st_nlink,
            ",\nst_ino: ", self.st_ino,
            ",\nst_uid: ", self.st_uid,
            ",\nst_gid: ", self.st_gid,
            ",\nst_rdev: ", self.st_rdev,
            ",\nst_size: ", self.st_size,
            ",\nst_blksize: ", self.st_blksize,
            ",\nst_blocks: ", self.st_blocks,
            ",\nst_atimespec: ", self.st_atimespec,
            ",\nst_mtimespec: ", self.st_mtimespec,
            ",\nst_ctimespec: ", self.st_ctimespec,
            ",\nst_birthtimespec: ", self.st_birthtimespec,
            "\n}",
        )
        # fmt: on

    def _to_stat_result(self) -> stat_result:
        return stat_result(
            st_dev=Int(self.st_dev),
            st_mode=Int(self.st_mode),
            st_nlink=Int(self.st_nlink),
            st_ino=Int(self.st_ino),
            st_uid=Int(self.st_uid),
            st_gid=Int(self.st_gid),
            st_rdev=Int(self.st_rdev),
            st_atimespec=self.st_atimespec,
            st_ctimespec=self.st_ctimespec,
            st_mtimespec=self.st_mtimespec,
            st_birthtimespec=self.st_birthtimespec,
            st_size=Int(self.st_size),
            st_blocks=Int(self.st_blocks),
            st_blksize=Int(self.st_blksize),
            st_flags=0,
        )


@inline(.always)
def _stat(var path: String) raises -> _c_stat:
    var stat = _c_stat()
    var err = external_call["stat", Int32](
        path.as_c_string_span(), Pointer(to=stat)
    )
    if err == -1:
        raise Error("unable to stat '", path, "'")
    return stat^


@inline(.always)
def _lstat(var path: String) raises -> _c_stat:
    var stat = _c_stat()
    var err = external_call["lstat", Int32](
        path.as_c_string_span(), Pointer(to=stat)
    )
    if err == -1:
        raise Error("unable to lstat '", path, "'")
    return stat^
