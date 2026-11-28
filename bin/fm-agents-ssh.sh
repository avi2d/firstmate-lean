#!/bin/bash -p
# Usage: fm-agents-ssh.sh <installed-code-root> <permitted-execution-home>
exec /usr/bin/python3 -I -c '
import base64
import binascii
import os
import re
import sys

PROTOCOL = "1"
BASE64 = r"[A-Za-z0-9+/]+={0,2}"
EFFORTS = {"default", "low", "medium", "high", "xhigh", "max", "ultra"}
SHIP_MODES = {"no-mistakes", "direct-PR"}
HARNESSES = {"pi", "pi-signed"}


def refuse(reason):
    sys.exit(f"fm-agents-ssh: {reason}")


def safe_id(value):
    return re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9._-]*", value) and ".." not in value


def selector(value):
    return re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9._:/@+-]*", value)


def bounded_integer(value, low, high):
    return re.fullmatch(r"[0-9]{1,10}", value) and low <= int(value) <= high


def valid_options(args, rules):
    seen = set()
    while args:
        name, *args = args
        if name not in rules or name in seen:
            return False
        seen.add(name)
        validate = rules[name]
        if validate is not None:
            if not args or not validate(args[0]):
                return False
            args = args[1:]
    return True


def valid_doctor(args):
    return valid_options(args, {
        "--fix": None,
        "--backend": lambda value: value in {"herdr", "any"},
        "--session": safe_id,
    })


def valid_launch(args):
    if len(args) not in {10, 11}:
        return False
    project, kind, mode, yolo, prefix, base, harness, model, effort, backend, *account = args
    delivery = (kind == "scout" and mode == yolo == "-") or (
        kind == "ship" and mode in SHIP_MODES and yolo in {"on", "off"}
    )
    return (
        safe_id(project) and delivery
        and (not prefix or re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9._/-]*", prefix))
        and (base == "-" or selector(base)) and harness in HARNESSES
        and (model == "-" or selector(model)) and (effort == "-" or effort in EFFORTS)
        and backend == "herdr" and (not account or safe_id(account[0]))
    )


def valid_worker(args):
    if not args:
        return False
    verb, *args = args
    if verb == "capabilities":
        return args in ([], ["worker-name"])
    if verb == "fleet":
        return not args
    if verb == "claude-account-check":
        return (
            len(args) == 3 and args[0] in HARNESSES and selector(args[1])
            and args[1].startswith("claude-bridge/") and safe_id(args[2])
        )
    if not args or not safe_id(args[0]):
        return False
    task, *args = args
    if verb in {"route", "state", "ci-repository", "resolve-stdin", "interrupt",
                "exit", "teardown", "crew-state"}:
        return not args
    if verb == "admit":
        return len(args) == 1 and safe_id(args[0])
    if verb == "capture":
        return not args or (len(args) == 1 and bounded_integer(args[0], 1, 100))
    if verb == "launch":
        return valid_launch(args)
    if verb == "send-stdin":
        return args in ([], ["fire-and-forget"], ["until-rung"])
    if verb == "key":
        return len(args) == 1 and args[0].lower() in {
            "enter", "escape", "esc", "c-c", "ctrl+c", "c-u", "ctrl+u"
        }
    if verb == "ring":
        return args in ([], [f"fm-{task}"])
    if verb == "ring-record":
        return len(args) == 1 and re.fullmatch(r"[0-9]{1,18}\.msg", args[0])
    if verb == "done-gate":
        return len(args) == 1 and re.fullmatch(r"done(?: \[at=[0-9]+\])?: *\S[^\n\r]*", args[0])
    if verb == "relaunch":
        return valid_options(args, {
            "--harness": lambda value: value in HARNESSES,
            "--model": selector,
            "--effort": lambda value: value in EFFORTS,
            "--claude-account": safe_id,
            "--note": lambda value: bool(value.strip()) and not value.startswith("--"),
        })
    return False


def valid_file(args):
    if len(args) not in {2, 3} or args[0] != "get":
        return False
    parts = args[1].split("/")
    if len(parts) < 3 or parts[0] != "data" or not all(safe_id(part) for part in parts[1:]):
        return False
    name = parts[-1]
    report = name.endswith(".md") or (
        len(parts) == 3 and re.fullmatch(r"nm-.*-findings.*\.txt", name)
    )
    return report and (len(args) == 2 or bounded_integer(args[2], 1, 1048576))


def encode(value):
    return base64.b64encode(os.fsencode(value)).decode("ascii")


def canonical_install_path(path):
    return (
        path.startswith("/") and path != "/" and not re.search(r"[\x00-\x1f\x7f]", path)
        and os.path.realpath(path) == path
    )


def main():
    if len(sys.argv) != 3:
        refuse("expected an installed code root and a permitted execution home")
    root, home = sys.argv[1:]
    if not canonical_install_path(root) or not os.path.isdir(root):
        refuse("installed code root must be a canonical absolute directory")
    if not canonical_install_path(home) or not os.path.isdir(os.path.dirname(home)):
        refuse("permitted execution home must have a canonical, existing parent")
    if os.path.lexists(home) and not os.path.isdir(home):
        refuse("permitted execution home is not a directory")
    if os.path.commonpath((root, home)) in {root, home}:
        refuse("code root and execution home must not overlap")

    original = os.environ.get("SSH_ORIGINAL_COMMAND")
    if not original:
        refuse("interactive login is not allowed")
    entrypoint = f"{root}/bin/fm-remote-entrypoint.sh"
    quote = chr(39)
    quoted_entrypoint = quote + entrypoint.replace(quote, quote + chr(92) + quote * 2) + quote
    prefix = quoted_entrypoint + " "
    if not original.startswith(prefix):
        refuse("command must name the installed remote entrypoint")
    fields = re.fullmatch(rf"{PROTOCOL} ({BASE64}) ({BASE64}) ({BASE64})", original[len(prefix):])
    if not fields:
        refuse("expected the fm-on.sh protocol 1 command format")
    root_token, home_token, argv_token = fields.groups()
    if root_token != encode(root):
        refuse("remote code root does not match the installed code root")
    if home_token != encode(home):
        refuse("remote home does not match the permitted execution home")

    try:
        decoded = base64.b64decode(argv_token, validate=True)
        if base64.b64encode(decoded).decode("ascii") != argv_token or not decoded.endswith(b"\0"):
            refuse("argv must be canonical base64 with NUL-terminated arguments")
        command, *args = decoded[:-1].decode("utf-8").split("\0")
    except (binascii.Error, UnicodeError):
        refuse("argv is not a valid encoded argument list")

    rules = {
        "fm-remote-doctor.sh": valid_doctor,
        "fm-remote-home-provision.sh": lambda args: not args,
        "fm-remote-worker-control.sh": valid_worker,
        "fm-remote-status-feed.sh": lambda args: not args or (
            len(args) == 1 and bounded_integer(args[0], 0, 300)
        ),
        "fm-remote-file.sh": valid_file,
    }
    if command not in rules:
        refuse("remote operation is not allowed")
    if any(any(not char.isprintable() and char not in "\t\n" for char in arg) for arg in args):
        refuse("remote arguments contain control characters")
    if not rules[command](args):
        refuse(f"arguments are not allowed for {command}")
    if os.path.realpath(entrypoint) != entrypoint or not os.path.isfile(entrypoint):
        refuse("installed remote entrypoint must be a regular file in the code root")

    try:
        os.execve(entrypoint, [entrypoint, PROTOCOL, encode(root), encode(home), argv_token],
                  {"PATH": "/usr/local/bin:/usr/bin:/bin"})
    except OSError as error:
        refuse(f"cannot execute installed remote entrypoint: {error.strerror}")


main()
' "$@"
