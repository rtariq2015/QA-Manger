"""Build-time only: produce the bundled offline production PDF interpreter."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import stat
import urllib.request


def linked(path: Path) -> bool:
    if not path.exists() and not path.is_symlink():
        return False
    value = path.lstat()
    return path.is_symlink() or bool(getattr(value, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--cache-dir", type=Path)
    parser.add_argument("--build-info", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = root / "App/Python"
    output = args.output_dir if args.output_dir is not None else source
    if linked(output):
        raise ValueError("The runtime output folder must be direct")
    output = output.resolve()
    if args.build_info:
        try:
            args.build_info.resolve().relative_to(output)
        except ValueError:
            pass
        else:
            raise ValueError("Build metadata must be outside the runtime folder")
    pins = json.loads((source / "Sources.json").read_text(encoding="utf-8"))
    worker = (source / "read_pdf.py").read_bytes()
    pins_bytes = (source / "Sources.json").read_bytes()
    helper_spec = importlib.util.spec_from_file_location("ctqa_probe_archive_helper", root / "scripts/build_python_probe.py")
    helper = importlib.util.module_from_spec(helper_spec)
    helper_spec.loader.exec_module(helper)
    entries = {"read_pdf.py": worker, "Sources.json": pins_bytes}
    case_names = {name.casefold() for name in entries}
    for dependency, prefix in [("python", "runtime/"), ("pypdf", "vendor/")]:
        pin = pins[dependency]
        if not pin["url"].startswith("https://"):
            raise ValueError("Pinned dependencies require HTTPS")
        cached = args.cache_dir / (dependency + "-" + pin["version"] + ".zip") if args.cache_dir else None
        if cached and cached.exists():
            data = cached.read_bytes()
        else:
            with urllib.request.urlopen(pin["url"], timeout=120) as response:
                data = response.read(52428801)
            if len(data) > 52428800:
                raise ValueError("Dependency download limit exceeded")
        if hashlib.sha256(data).hexdigest() != pin["sha256"]:
            raise ValueError("Pinned dependency checksum mismatch: " + dependency)
        if cached and not cached.exists():
            cached.parent.mkdir(parents=True, exist_ok=True)
            cached.write_bytes(data)
        for name, body in helper.safe_members(data):
            target_name = prefix + name
            if target_name.casefold() in case_names:
                raise ValueError("Duplicate dependency member")
            if any(part.endswith((".", " ")) for part in Path(name).parts):
                raise ValueError("Ambiguous Windows dependency member")
            case_names.add(target_name.casefold())
            entries[target_name] = body
    pth = "python" + "".join(pins["python"]["version"].split(".")[:2]) + "._pth"
    if "runtime/" + pth not in entries:
        raise ValueError("The runtime path configuration is missing")
    entries["runtime/" + pth] = (pth.replace("._pth", ".zip") + "\r\n.\r\n../vendor\r\n# site remains disabled\r\n").encode("ascii")
    manifest = {"SchemaVersion": 1, "PythonVersion": pins["python"]["version"], "PypdfVersion": pins["pypdf"]["version"], "Files": [{"Name": name, "SHA256": hashlib.sha256(data).hexdigest().upper()} for name, data in sorted(entries.items())]}
    manifest_bytes = (json.dumps(manifest, indent=2) + "\n").encode("utf-8")
    output.mkdir(parents=True, exist_ok=True)
    for name in ["runtime", "vendor"]:
        current = output / name
        if linked(current):
            raise ValueError("Runtime components must not be linked")
        if current.exists():
            shutil.rmtree(current)
    for name, data in sorted(entries.items()):
        path = output / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if linked(path):
            raise ValueError("Runtime components must not be linked")
        path.write_bytes(data)
    (output / "Integrity.json").write_bytes(manifest_bytes)
    info = {"schemaVersion": 1, "pythonVersion": pins["python"]["version"], "pypdfVersion": pins["pypdf"]["version"], "files": len(entries), "bytes": sum(map(len, entries.values())), "integritySHA256": hashlib.sha256(manifest_bytes).hexdigest(), "sources": pins}
    if args.build_info:
        args.build_info.parent.mkdir(parents=True, exist_ok=True)
        args.build_info.write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({name: value for name, value in info.items() if name != "sources"}, indent=2))


if __name__ == "__main__":
    main()
