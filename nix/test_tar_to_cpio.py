#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import io
import os
import stat
import tarfile
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(os.environ.get("TAR_TO_CPIO", Path(__file__).with_name("tar-to-cpio.py")))
SPEC = importlib.util.spec_from_file_location("tar_to_cpio", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
tar_to_cpio = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tar_to_cpio)


def parse_newc(payload: bytes) -> dict[str, dict[str, int | bytes]]:
    offset = 0
    entries: dict[str, dict[str, int | bytes]] = {}
    while True:
        header = payload[offset : offset + 110]
        if len(header) != 110 or header[:6] != b"070701":
            raise AssertionError(f"bad newc header at offset {offset}")
        values = [int(header[i : i + 8], 16) for i in range(6, 110, 8)]
        (
            inode,
            mode,
            uid,
            gid,
            nlink,
            mtime,
            size,
            devmajor,
            devminor,
            rdevmajor,
            rdevminor,
            namesize,
            checksum,
        ) = values
        offset += 110
        name_bytes = payload[offset : offset + namesize]
        if not name_bytes.endswith(b"\0"):
            raise AssertionError("newc name is not NUL-terminated")
        name = name_bytes[:-1].decode()
        offset += namesize
        offset += (-offset) % 4
        data = payload[offset : offset + size]
        offset += size
        offset += (-offset) % 4
        if name == "TRAILER!!!":
            break
        entries[name] = {
            "inode": inode,
            "mode": mode,
            "uid": uid,
            "gid": gid,
            "nlink": nlink,
            "mtime": mtime,
            "size": size,
            "devmajor": devmajor,
            "devminor": devminor,
            "rdevmajor": rdevmajor,
            "rdevminor": rdevminor,
            "checksum": checksum,
            "data": data,
        }
    return entries


class TarToCpioTests(unittest.TestCase):
    def make_archive(self, path: Path) -> None:
        with tarfile.open(path, "w", format=tarfile.PAX_FORMAT) as archive:
            for name in [
                "rootfs",
                "rootfs/var",
                "rootfs/var/lib",
                "rootfs/var/lib/oci",
                "rootfs/var/lib/oci/bundle",
            ]:
                entry = tarfile.TarInfo(name)
                entry.type = tarfile.DIRTYPE
                entry.mode = 0o755
                entry.uid = 0
                entry.gid = 0
                entry.mtime = 1
                archive.addfile(entry)

            tool = tarfile.TarInfo("rootfs/var/lib/oci/bundle/tool")
            tool.mode = 0o4750
            tool.uid = 123
            tool.gid = 456
            tool.mtime = 1
            tool.size = len(b"payload")
            archive.addfile(tool, io.BytesIO(b"payload"))

            hardlink = tarfile.TarInfo("rootfs/var/lib/oci/bundle/tool-link")
            hardlink.type = tarfile.LNKTYPE
            hardlink.linkname = tool.name
            hardlink.mode = tool.mode
            hardlink.uid = tool.uid
            hardlink.gid = tool.gid
            hardlink.mtime = 1
            archive.addfile(hardlink)

            symlink = tarfile.TarInfo("rootfs/var/lib/oci/bundle/tool-symlink")
            symlink.type = tarfile.SYMTYPE
            symlink.linkname = "tool"
            symlink.mode = 0o777
            symlink.uid = 321
            symlink.gid = 654
            symlink.mtime = 1
            archive.addfile(symlink)

            device = tarfile.TarInfo("rootfs/var/lib/oci/bundle/device")
            device.type = tarfile.CHRTYPE
            device.mode = 0o600
            device.uid = 0
            device.gid = 5
            device.devmajor = 10
            device.devminor = 200
            device.mtime = 1
            archive.addfile(device)

    def test_metadata_and_hardlinks_survive_conversion(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "bundle.tar"
            self.make_archive(archive)

            first = io.BytesIO()
            tar_to_cpio.convert(archive, first)
            second = io.BytesIO()
            tar_to_cpio.convert(archive, second)
            self.assertEqual(first.getvalue(), second.getvalue())

            entries = parse_newc(first.getvalue())
            tool = entries["rootfs/var/lib/oci/bundle/tool"]
            link = entries["rootfs/var/lib/oci/bundle/tool-link"]
            self.assertEqual(stat.S_IFMT(tool["mode"]), stat.S_IFREG)
            self.assertEqual(tool["mode"] & 0o7777, 0o4750)
            self.assertEqual((tool["uid"], tool["gid"]), (123, 456))
            self.assertEqual(tool["data"], b"payload")
            self.assertEqual(tool["nlink"], 2)
            self.assertEqual(link["nlink"], 2)
            self.assertEqual(tool["inode"], link["inode"])
            self.assertEqual(link["size"], 0)

            symlink = entries["rootfs/var/lib/oci/bundle/tool-symlink"]
            self.assertEqual(stat.S_IFMT(symlink["mode"]), stat.S_IFLNK)
            self.assertEqual((symlink["uid"], symlink["gid"]), (321, 654))
            self.assertEqual(symlink["data"], b"tool")

            device = entries["rootfs/var/lib/oci/bundle/device"]
            self.assertEqual(stat.S_IFMT(device["mode"]), stat.S_IFCHR)
            self.assertEqual((device["rdevmajor"], device["rdevminor"]), (10, 200))

    def test_paths_outside_rootfs_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "unsafe.tar"
            with tarfile.open(archive, "w") as output:
                member = tarfile.TarInfo("etc/shadow")
                member.size = 0
                output.addfile(member, io.BytesIO())
            with self.assertRaises(tar_to_cpio.ConversionError):
                tar_to_cpio.convert(archive, io.BytesIO())


if __name__ == "__main__":
    unittest.main()
