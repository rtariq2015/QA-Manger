"""Build-time only: pinned Windows embedded Python and a vendored PDF reader."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path, PurePosixPath
import urllib.request
import zipfile


def safe_members(content: bytes):
    with zipfile.ZipFile(io.BytesIO(content)) as archive:
        for item in archive.infolist():
            if item.is_dir():
                continue
            name = item.filename
            parts = PurePosixPath(name).parts
            mode = item.external_attr >> 16
            if "\\" in name or ":" in name or not parts or name.startswith("/") or ".." in parts or (mode & 0o170000) == 0o120000:
                raise ValueError("Unsafe dependency archive entry")
            yield name, archive.read(item)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--cache-dir", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = root / "Tools/PythonProbe"
    pins = json.loads((source / "Sources.json").read_text())
    entries = {}
    for name in ["probe.py", "Run Python Test.cmd", "READ FIRST.txt", "Sources.json"]:
        entries[name] = (source / name).read_bytes()
    for dependency, prefix in [("python", "runtime/"), ("pypdf", "vendor/")]:
        pin = pins[dependency]
        if not pin["url"].startswith("https://"):
            raise ValueError("Dependencies require pinned HTTPS sources")
        cache = args.cache_dir / (dependency + "-" + pin["version"] + ".zip") if args.cache_dir else None
        if cache and cache.exists():
            content = cache.read_bytes()
        else:
            with urllib.request.urlopen(pin["url"], timeout=120) as response:
                content = response.read(50 * 1024 * 1024)
            if cache:
                cache.parent.mkdir(parents=True, exist_ok=True)
                cache.write_bytes(content)
        if hashlib.sha256(content).hexdigest() != pin["sha256"]:
            raise ValueError("Pinned dependency checksum mismatch: " + dependency)
        for name, content in safe_members(content):
            if prefix + name in entries:
                raise ValueError("Duplicate dependency file")
            entries[prefix + name] = content
    pth = "python" + "".join(pins["python"]["version"].split(".")[:2]) + "._pth"
    if "runtime/" + pth not in entries:
        raise ValueError("Embedded runtime path configuration is missing")
    zipname = pth.replace("._pth", ".zip")
    entries["runtime/" + pth] = (zipname + "\r\n.\r\n../vendor\r\n# site remains disabled\r\n").encode("ascii")
    spec = importlib.util.spec_from_file_location("ctqa_python_probe_build_fixtures", source / "probe.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for name, content in module.fixture_bytes().items():
        entries["Fixtures/" + name] = content
    package = {"schemaVersion": 1, "name": "CT QA Portable Python Test", "version": module.VERSION, "pythonVersion": pins["python"]["version"], "pypdfVersion": pins["pypdf"]["version"]}
    entries["Package.json"] = (json.dumps(package, indent=2) + "\n").encode()
    entries["Package-SHA256SUMS.txt"] = "".join(hashlib.sha256(body).hexdigest() + "  " + name + "\n" for name, body in sorted(entries.items())).encode()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    output = args.output_dir / ("CT_QA_Python_Portable_Test_v" + module.VERSION + ".zip")
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, content in sorted(entries.items()):
            item = zipfile.ZipInfo("CT_QA_Python_Portable_Test/" + name, date_time=(2026, 1, 1, 0, 0, 0))
            item.compress_type = zipfile.ZIP_DEFLATED
            item.external_attr = 0o100644 << 16
            archive.writestr(item, content)
    info = {"schemaVersion": 1, "package": output.name, "sha256": hashlib.sha256(output.read_bytes()).hexdigest(), "bytes": output.stat().st_size, "files": len(entries), "pythonVersion": pins["python"]["version"], "pypdfVersion": pins["pypdf"]["version"], "sources": pins}
    (args.output_dir / "Build-Info.json").write_text(json.dumps(info, indent=2) + "\n")
    print(json.dumps({k: v for k, v in info.items() if k != "sources"}, indent=2))


if __name__ == "__main__":
    main()
