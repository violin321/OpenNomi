#!/usr/bin/env python3
"""Check IPA structure, iOS device architecture, and installation metadata."""

import datetime
import hashlib
import json
import plistlib
import struct
import subprocess
import sys
from pathlib import Path
from zipfile import ZipFile


def verify(path: Path) -> dict:
    with ZipFile(path) as archive:
        corrupt = archive.testzip()
        if corrupt:
            raise ValueError(f"Corrupt ZIP entry: {corrupt}")
        names = archive.namelist()
        info_paths = [
            name for name in names
            if name.startswith("Payload/")
            and name.endswith(".app/Info.plist")
            and name.count("/") == 2
        ]
        if len(info_paths) != 1:
            raise ValueError("Expected exactly one top-level iOS app")
        info = plistlib.loads(archive.read(info_paths[0]))
        if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
            raise ValueError("App must target iOS devices")
        if info.get("CFBundlePackageType") != "APPL":
            raise ValueError("Invalid application package type")
        app_prefix = info_paths[0].removesuffix("Info.plist")
        executable = info["CFBundleExecutable"]
        binary = archive.read(app_prefix + executable)
        if len(binary) < 32 or struct.unpack_from("<II", binary) != (0xFEEDFACF, 0x0100000C):
            raise ValueError("Expected a 64-bit arm64 Mach-O executable")
        command_count = struct.unpack_from("<I", binary, 16)[0]
        offset = 32
        ios_platform = False
        for _ in range(command_count):
            command, size = struct.unpack_from("<II", binary, offset)
            if size < 8 or offset + size > len(binary):
                raise ValueError("Invalid Mach-O load command")
            if command == 0x32:  # LC_BUILD_VERSION
                ios_platform = struct.unpack_from("<I", binary, offset + 8)[0] == 2
            offset += size
        if not ios_platform:
            raise ValueError("Mach-O must declare the iOS device platform")
        for required in ("NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"):
            if not info.get(required):
                raise ValueError(f"Missing permission description: {required}")
        if any(name.endswith("embedded.mobileprovision") for name in names):
            raise ValueError("Unexpected provisioning profile in unsigned build")
        return {
            "artifact": path.name,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "size_bytes": path.stat().st_size,
            "bundle_identifier": info["CFBundleIdentifier"],
            "version": info["CFBundleShortVersionString"],
            "build": info["CFBundleVersion"],
            "minimum_ios": info["MinimumOSVersion"],
            "architecture": "arm64",
            "platform": "iPhoneOS",
            "signing": "unsigned; requires signing before installation",
        }


def main() -> None:
    path = Path(sys.argv[1]).resolve()
    receipt = verify(path)
    receipt.update({
        "built_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
        "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
    })
    output = path.with_name("build-receipt.json")
    output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print(output.read_text(), end="")


if __name__ == "__main__":
    main()
