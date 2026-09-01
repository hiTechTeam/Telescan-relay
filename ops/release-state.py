#!/usr/bin/env python3
"""Durable state and atomic pointer operations for production releases."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import tempfile
from pathlib import Path


SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
IMAGE_ID = re.compile(r"^sha256:[0-9a-f]{64}$")
PHASES = {"prepared", "candidate_ready", "promoted", "committed"}


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def safe_name(value: str, label: str) -> str:
    if not SAFE_NAME.fullmatch(value) or value in {".", ".."}:
        raise SystemExit(f"invalid {label}: {value!r}")
    return value


def validate_image(value: str, label: str, *, pending: bool = False) -> str:
    if pending and value == "pending":
        return value
    if value and not IMAGE_ID.fullmatch(value):
        raise SystemExit(f"invalid {label}: {value!r}")
    return value


def durable_json(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        fsync_directory(path.parent)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def load_intent(path: Path) -> dict[str, object]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"cannot read durable release intent {path}: {error}") from error
    required = {"version", "kind", "phase", "old_release", "new_release"}
    if not isinstance(payload, dict) or not required.issubset(payload):
        raise SystemExit("durable release intent is incomplete")
    if payload["version"] != 1 or payload["phase"] not in PHASES:
        raise SystemExit("durable release intent has unsupported version or phase")
    safe_name(str(payload["old_release"]), "old release")
    safe_name(str(payload["new_release"]), "new release")
    validate_image(str(payload.get("old_image_id", "")), "old image id")
    validate_image(str(payload.get("new_image_id", "")), "new image id", pending=True)
    manifest = str(payload.get("old_images_manifest", ""))
    if manifest:
        safe_name(manifest, "image manifest")
    new_manifest = str(payload.get("new_images_manifest", ""))
    if new_manifest:
        safe_name(new_manifest, "new image manifest")
    return payload


def command_write(args: argparse.Namespace) -> None:
    if args.phase not in PHASES:
        raise SystemExit("unsupported release phase")
    payload: dict[str, object] = {
        "version": 1,
        "kind": safe_name(args.kind, "release kind"),
        "phase": args.phase,
        "old_release": safe_name(args.old_release, "old release"),
        "new_release": safe_name(args.new_release, "new release"),
        "image_reference": args.image_reference,
        "old_image_reference": args.old_image_reference,
        "rollback_image_reference": args.rollback_image_reference,
        "old_image_id": validate_image(args.old_image_id, "old image id"),
        "new_image_id": validate_image(args.new_image_id, "new image id", pending=True),
        "old_images_manifest": (
            safe_name(args.old_images_manifest, "image manifest")
            if args.old_images_manifest
            else ""
        ),
        "new_images_manifest": (
            safe_name(args.new_images_manifest, "new image manifest")
            if args.new_images_manifest
            else ""
        ),
    }
    durable_json(Path(args.intent), payload)


def command_update(args: argparse.Namespace) -> None:
    path = Path(args.intent)
    payload = load_intent(path)
    if args.phase:
        if args.phase not in PHASES:
            raise SystemExit("unsupported release phase")
        payload["phase"] = args.phase
    if args.new_image_id:
        payload["new_image_id"] = validate_image(args.new_image_id, "new image id")
    durable_json(path, payload)


def command_get(args: argparse.Namespace) -> None:
    payload = load_intent(Path(args.intent))
    if args.field not in payload or isinstance(payload[args.field], (dict, list)):
        raise SystemExit(f"intent field is unavailable: {args.field}")
    print(payload[args.field])


def command_clear(args: argparse.Namespace) -> None:
    path = Path(args.intent)
    path.unlink()
    fsync_directory(path.parent)


def command_switch(args: argparse.Namespace) -> None:
    active = Path(args.active_root).resolve(strict=True)
    release_name = safe_name(args.release, "release")
    releases = active / "releases"
    target = releases / release_name
    if target.is_symlink() or not target.is_dir():
        raise SystemExit(f"release directory is missing or unsafe: {target}")
    if target.parent.resolve(strict=True) != releases.resolve(strict=True):
        raise SystemExit("release escaped the release root")
    temporary = active / f".current.{os.getpid()}"
    try:
        os.symlink(f"releases/{release_name}", temporary)
        os.replace(temporary, active / "current")
        fsync_directory(active)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def command_switch_path(args: argparse.Namespace) -> None:
    root = Path(args.root).resolve(strict=True)
    link_name = safe_name(args.link, "link")
    target_parts = Path(args.target).parts
    if not target_parts or any(part in {"", ".", ".."} for part in target_parts):
        raise SystemExit("unsafe relative pointer target")
    target = root.joinpath(*target_parts)
    if target.is_symlink() or not target.is_dir() or root not in target.resolve(strict=True).parents:
        raise SystemExit("pointer target is missing or escaped its root")
    temporary = root / f".{link_name}.{os.getpid()}"
    try:
        os.symlink(str(Path(*target_parts)), temporary)
        os.replace(temporary, root / link_name)
        fsync_directory(root)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def command_sync_tree(args: argparse.Namespace) -> None:
    root = Path(args.path).resolve(strict=True)
    if not root.is_dir():
        raise SystemExit("sync-tree path must be a directory")
    directories: list[Path] = []
    for current, dirnames, filenames in os.walk(root, followlinks=False):
        current_path = Path(current)
        directories.append(current_path)
        for filename in filenames:
            path = current_path / filename
            try:
                mode = path.lstat().st_mode
                if stat.S_ISREG(mode):
                    descriptor = os.open(path, os.O_RDONLY)
                    try:
                        os.fsync(descriptor)
                    finally:
                        os.close(descriptor)
            except FileNotFoundError:
                raise SystemExit(f"release changed while syncing: {path}")
        dirnames[:] = [name for name in dirnames if not (current_path / name).is_symlink()]
    for directory in reversed(directories):
        fsync_directory(directory)
    # Persist the release directory entry itself before an intent or current
    # pointer is allowed to reference it.
    fsync_directory(root.parent)


def command_sync_dir(args: argparse.Namespace) -> None:
    path = Path(args.path).resolve(strict=True)
    if not path.is_dir():
        raise SystemExit("sync-dir path must be a directory")
    fsync_directory(path)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)

    write = commands.add_parser("write-intent")
    write.add_argument("--intent", required=True)
    write.add_argument("--kind", required=True)
    write.add_argument("--phase", required=True)
    write.add_argument("--old-release", required=True)
    write.add_argument("--new-release", required=True)
    write.add_argument("--image-reference", default="")
    write.add_argument("--old-image-reference", default="")
    write.add_argument("--rollback-image-reference", default="")
    write.add_argument("--old-image-id", default="")
    write.add_argument("--new-image-id", default="")
    write.add_argument("--old-images-manifest", default="")
    write.add_argument("--new-images-manifest", default="")
    write.set_defaults(handler=command_write)

    update = commands.add_parser("update-intent")
    update.add_argument("--intent", required=True)
    update.add_argument("--phase")
    update.add_argument("--new-image-id")
    update.set_defaults(handler=command_update)

    get = commands.add_parser("get")
    get.add_argument("--intent", required=True)
    get.add_argument("--field", required=True)
    get.set_defaults(handler=command_get)

    clear = commands.add_parser("clear")
    clear.add_argument("--intent", required=True)
    clear.set_defaults(handler=command_clear)

    switch = commands.add_parser("switch")
    switch.add_argument("--active-root", required=True)
    switch.add_argument("--release", required=True)
    switch.set_defaults(handler=command_switch)

    switch_path = commands.add_parser("switch-path")
    switch_path.add_argument("--root", required=True)
    switch_path.add_argument("--link", required=True)
    switch_path.add_argument("--target", required=True)
    switch_path.set_defaults(handler=command_switch_path)

    sync_tree = commands.add_parser("sync-tree")
    sync_tree.add_argument("--path", required=True)
    sync_tree.set_defaults(handler=command_sync_tree)

    sync_dir = commands.add_parser("sync-dir")
    sync_dir.add_argument("--path", required=True)
    sync_dir.set_defaults(handler=command_sync_dir)
    return root


def main() -> None:
    args = parser().parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
