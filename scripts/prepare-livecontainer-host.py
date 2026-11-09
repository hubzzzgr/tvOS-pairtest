#!/usr/bin/env python3
"""Prepare a copy of an existing combined LiveContainer IPA for re-signing.

Only the top-level app's local-network declarations change. Never modifies the
input, signs, installs, refreshes, or changes bundled SideStore/frameworks.
Requires Python 3; runnable on the existing macOS build runner.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import zipfile

SERVICES = (
    "_remotepairing._tcp", "_remotepairing-manual-pairing._tcp",
    "_remoted._tcp", "_apple-mobdev2._tcp",
    "_remotepairing-pairable-host._tcp", "_airplay._tcp",
    "_companion-link._tcp",
)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def prepare(source, destination, expected_version, expected_hash):
    source, destination = source.resolve(strict=True), destination.resolve()
    if source == destination or destination.exists():
        raise ValueError("Output must be a new file; input and existing files are never overwritten")
    if digest(source) != expected_hash.lower():
        raise ValueError("Input IPA does not match the explicitly selected source SHA-256")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(source) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        if len(set(names)) != len(names) or len(names) > 20000:
            raise ValueError("Duplicate entries or excessive archive size")
        if sum(entry.file_size for entry in entries) > 1_073_741_824:
            raise ValueError("Uncompressed archive exceeds preparation limit")
        for name in names:
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or "\\" in name:
                raise ValueError("Invalid archive path")
        mains = [name for name in names if name.startswith("Payload/")
                 and name.count("/") == 2 and name.endswith(".app/Info.plist")]
        if len(mains) != 1:
            raise ValueError("Expected exactly one top-level application")
        main = mains[0]
        if archive.getinfo(main).file_size > 1_048_576:
            raise ValueError("Oversized app metadata")
        original = plistlib.loads(archive.read(main))
        if "LiveContainer" not in str(original.get("CFBundleName", "")):
            raise ValueError("Input is not a LiveContainer host")
        if original.get("CFBundleShortVersionString") != expected_version:
            raise ValueError("Host version differs from the installed version selected by the user")
        root = main.removesuffix("Info.plist")
        if root + "Frameworks/SideStoreApp.framework/Info.plist" not in names:
            raise ValueError("Expected the SideStore-integrated variant")
        info = copy.deepcopy(original)
        services = info.setdefault("NSBonjourServices", [])
        if not isinstance(services, list) or not all(isinstance(item, str) for item in services):
            raise ValueError("Invalid existing Bonjour declarations")
        added = [item for item in SERVICES if item not in services]
        services.extend(added)
        if not info.get("NSLocalNetworkUsageDescription"):
            info["NSLocalNetworkUsageDescription"] = "Guest apps discover and connect to devices on your local network."
        payload = plistlib.dumps(info, fmt=plistlib.FMT_BINARY, sort_keys=False)
        try:
            with zipfile.ZipFile(destination, "w", allowZip64=True) as output:
                output.comment = archive.comment
                for entry in entries:
                    metadata = copy.copy(entry)
                    if entry.filename == main:
                        output.writestr(metadata, payload)
                    else:
                        with archive.open(entry) as reader, output.open(metadata, "w") as writer:
                            shutil.copyfileobj(reader, writer)
            # Package integrity verification: every other entry must be byte
            # identical, including the embedded SideStore and its frameworks.
            with zipfile.ZipFile(destination) as output:
                if output.namelist() != names:
                    raise ValueError("Archive entry list changed")
                for entry in entries:
                    if entry.filename == main:
                        continue
                    with archive.open(entry) as before, output.open(entry.filename) as after:
                        if hashlib.file_digest(before, "sha256").digest() != hashlib.file_digest(after, "sha256").digest():
                            raise ValueError("A non-metadata entry changed")
                if plistlib.loads(output.read(main)) != info:
                    raise ValueError("Prepared metadata did not round-trip")
        except BaseException:
            destination.unlink(missing_ok=True)
            raise
    report = {
        "source_sha256": expected_hash.lower(), "output_sha256": digest(destination),
        "version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion"),
        "bundle_identifier": info.get("CFBundleIdentifier"), "added_services": added,
        "changed_entry": main, "embedded_content": "byte-identical",
        "installation": "Requires re-signing as the existing host identity; not signed or installed by this script",
    }
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--source-sha256", required=True)
    args = parser.parse_args()
    prepare(args.source, args.destination, args.expected_version, args.source_sha256)
