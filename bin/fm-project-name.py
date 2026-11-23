#!/usr/bin/env python3
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit


def remote_identity(project):
    root = subprocess.run(
        ["git", "-C", project, "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=False,
    )
    if root.returncode or Path(root.stdout.strip()).resolve() != Path(project).resolve():
        return None
    result = subprocess.run(
        ["git", "-C", project, "remote", "get-url", "origin"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        return None
    url = result.stdout.strip()
    if "://" not in url:
        match = re.fullmatch(r"(?:[^@/:]+@)?([^/:]+):(.+)", url)
        if not match:
            return None
        url = "ssh://" + match.group(1) + "/" + match.group(2)
    parsed = urlsplit(url)
    if parsed.scheme not in {"https", "http", "ssh", "git"} or not parsed.hostname:
        return None
    try:
        port = f":{parsed.port}" if parsed.port else ""
    except ValueError:
        return None
    path = parsed.path.strip("/")
    if path.endswith(".git"):
        path = path[:-4]
    return parsed.hostname.lower() + port + "/" + path if path else None


def registry_name(registry, project):
    fallback = os.path.basename(os.path.normpath(project))
    identity = remote_identity(project)
    if not identity or not registry.is_file():
        return fallback
    candidate = re.compile(
        r"(?<![A-Za-z0-9_.@/-])(?:(?:https?://|ssh://)(?:[^/@\s]+@)?|git@)?"
        r"([A-Za-z0-9.-]+(?::[0-9]+)?)/([A-Za-z0-9._~/-]+)"
    )
    matches = []
    for line in registry.read_text(encoding="utf-8").splitlines():
        row = re.match(r"^- (.*?)(?: \[| - |$)", line)
        if not row:
            continue
        for found in candidate.finditer(line[row.end():]):
            path = found.group(2).rstrip("./")
            if path.endswith(".git"):
                path = path[:-4]
            if found.group(1).lower() + "/" + path == identity:
                matches.append(row.group(1))
                break
    if len(matches) > 1:
        raise ValueError("multiple registry entries name the checkout's origin")
    return matches[0] if matches else fallback


try:
    print(registry_name(Path(sys.argv[1]), sys.argv[2]))
except (OSError, UnicodeError, ValueError) as error:
    print(f"error: project registry lookup failed: {error}", file=sys.stderr)
    sys.exit(3)
