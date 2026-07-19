#!/usr/bin/env python3
"""Convert an OCI payload tar to a Linux initramfs ``newc`` archive.

The conversion is deliberately archive-to-archive.  Extracting the tar into a
Nix derivation output would send the tree through NAR canonicalisation before
nitro-util creates the initramfs, losing hardlinks, ownership, and permission
bits again.

Linux's initramfs format has no representation for xattrs or ACLs.  They stay
intact in the transport tar (and can be consumed by a future rootfs format),
but the ``newc`` output can carry only the metadata fields defined by the
kernel: inode identity, mode, uid/gid, link count, mtime, and device numbers.
"""

from __future__ import annotations

import argparse
import os
import posixpath
import stat
import sys
import tarfile
from typing import BinaryIO


NEWC_MAGIC = b"070701"
TRAILER = "TRAILER!!!"
UINT32_MAX = (1 << 32) - 1


class ConversionError(Exception):
    """The input cannot be represented safely as an initramfs archive."""


def _checked_u32(label: str, value: int) -> int:
    if value < 0 or value > UINT32_MAX:
        raise ConversionError(f"{label} does not fit in a newc field: {value}")
    return value


def _archive_name(raw_name: str) -> str:
    # umoci emits clean relative names.  Keep this check here because this
    # converter runs during a trusted Nix build but consumes a caller-supplied
    # archive; an absolute path or '..' must never become an initramfs member.
    name = raw_name.rstrip("/")
    if not name or name == ".":
        raise ConversionError(f"invalid empty archive path: {raw_name!r}")
    if name.startswith("/") or "\x00" in name:
        raise ConversionError(f"unsafe archive path: {raw_name!r}")
    if any(part in ("", ".", "..") for part in name.split("/")):
        raise ConversionError(f"non-canonical archive path: {raw_name!r}")
    if posixpath.normpath(name) != name:
        raise ConversionError(f"non-canonical archive path: {raw_name!r}")
    if name != "rootfs" and not name.startswith("rootfs/"):
        raise ConversionError(f"archive entry is outside the rootfs payload: {raw_name!r}")
    return name


def _padding(size: int, alignment: int) -> int:
    return (-size) % alignment


def _write_padding(output: BinaryIO, size: int, alignment: int = 4) -> None:
    output.write(b"\0" * _padding(size, alignment))


def _write_header(
    output: BinaryIO,
    *,
    name: str,
    inode: int,
    mode: int,
    uid: int,
    gid: int,
    nlink: int,
    mtime: int,
    size: int,
    devmajor: int = 0,
    devminor: int = 0,
    rdevmajor: int = 0,
    rdevminor: int = 0,
) -> None:
    name_bytes = os.fsencode(name)
    if b"\0" in name_bytes:
        raise ConversionError(f"archive path contains NUL: {name!r}")

    fields = (
        _checked_u32("inode", inode),
        _checked_u32(f"mode for {name}", mode),
        _checked_u32(f"uid for {name}", uid),
        _checked_u32(f"gid for {name}", gid),
        _checked_u32(f"link count for {name}", nlink),
        _checked_u32(f"mtime for {name}", mtime),
        _checked_u32(f"size for {name}", size),
        _checked_u32(f"device major for {name}", devmajor),
        _checked_u32(f"device minor for {name}", devminor),
        _checked_u32(f"rdevice major for {name}", rdevmajor),
        _checked_u32(f"rdevice minor for {name}", rdevminor),
        _checked_u32(f"name size for {name}", len(name_bytes) + 1),
        0,  # c_check is unused by the 070701 (newc) format.
    )
    header = NEWC_MAGIC + b"".join(f"{field:08x}".encode("ascii") for field in fields)
    if len(header) != 110:
        raise AssertionError(f"newc header has unexpected size {len(header)}")
    output.write(header)
    output.write(name_bytes)
    output.write(b"\0")
    _write_padding(output, len(header) + len(name_bytes) + 1)


def _member_type(member: tarfile.TarInfo, target: tarfile.TarInfo | None = None) -> int:
    source = target if member.islnk() else member
    if source is None:
        raise AssertionError("hardlink target was not resolved")
    if source.isfile():
        return stat.S_IFREG
    if source.isdir():
        return stat.S_IFDIR
    if source.issym():
        return stat.S_IFLNK
    if source.ischr():
        return stat.S_IFCHR
    if source.isblk():
        return stat.S_IFBLK
    if source.isfifo():
        return stat.S_IFIFO
    raise ConversionError(f"unsupported tar entry type for {member.name!r}")


def convert(input_path: os.PathLike[str] | str, output: BinaryIO) -> None:
    with tarfile.open(input_path, mode="r:") as archive:
        members = archive.getmembers()
        by_name: dict[str, tarfile.TarInfo] = {}
        clean_names: dict[int, str] = {}

        for member in members:
            name = _archive_name(member.name)
            if name in by_name:
                raise ConversionError(f"duplicate tar entry: {name!r}")
            by_name[name] = member
            clean_names[id(member)] = name

        def canonical(member: tarfile.TarInfo) -> tarfile.TarInfo:
            seen: set[str] = set()
            current = member
            while current.islnk():
                linkname = _archive_name(current.linkname)
                if linkname in seen:
                    raise ConversionError(f"hardlink cycle involving {linkname!r}")
                seen.add(linkname)
                try:
                    current = by_name[linkname]
                except KeyError as exc:
                    raise ConversionError(
                        f"hardlink {current.name!r} targets missing entry {linkname!r}"
                    ) from exc
            return current

        # newc represents hardlinks through equal (device, inode) tuples and a
        # link count.  Tar represents them by path, so resolve and count every
        # group before emitting the first member.
        group_size: dict[str, int] = {}
        for member in members:
            root = canonical(member)
            root_name = clean_names[id(root)]
            if root.isdir() and member.islnk():
                raise ConversionError(
                    f"hardlink {member.name!r} targets a directory"
                )
            group_size[root_name] = group_size.get(root_name, 0) + 1

        inode_for_root: dict[str, int] = {}
        next_inode = 1

        for member in members:
            name = clean_names[id(member)]
            root = canonical(member)
            root_name = clean_names[id(root)]
            inode = inode_for_root.get(root_name)
            if inode is None:
                inode = next_inode
                next_inode += 1
                inode_for_root[root_name] = inode

            # A tar hardlink has no independent inode metadata.  Use the
            # canonical target's fields for every link name so the first name
            # still creates the right inode even when it precedes the target.
            metadata = root if member.islnk() else member
            type_mode = _member_type(member, root)
            mode = type_mode | (metadata.mode & 0o7777)
            nlink = group_size[root_name] if not root.isdir() else 1

            data: BinaryIO | None = None
            inline_data: bytes | None = None
            if root.issym():
                # The kernel requires non-empty data for every symlink cpio
                # member, including names participating in a hardlink group.
                inline_data = os.fsencode(root.linkname)
                size = len(inline_data)
            elif member.islnk():
                size = 0
            elif member.isfile():
                size = member.size
                data = archive.extractfile(member)
                if data is None:
                    raise ConversionError(f"cannot read regular file {name!r}")
            else:
                size = 0

            _write_header(
                output,
                name=name,
                inode=inode,
                mode=mode,
                uid=metadata.uid,
                gid=metadata.gid,
                nlink=nlink,
                mtime=int(metadata.mtime),
                size=size,
                rdevmajor=metadata.devmajor if root.isdev() else 0,
                rdevminor=metadata.devminor if root.isdev() else 0,
            )

            if data is not None:
                remaining = size
                while remaining:
                    chunk = data.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise ConversionError(f"short read from tar member {name!r}")
                    output.write(chunk)
                    remaining -= len(chunk)
            elif inline_data is not None:
                output.write(inline_data)
            _write_padding(output, size)

        _write_header(
            output,
            name=TRAILER,
            inode=0,
            mode=0,
            uid=0,
            gid=0,
            nlink=1,
            mtime=0,
            size=0,
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", help="uncompressed OCI payload tar")
    args = parser.parse_args()
    try:
        convert(args.archive, sys.stdout.buffer)
    except (ConversionError, OSError, tarfile.TarError) as exc:
        print(f"tar-to-cpio: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
