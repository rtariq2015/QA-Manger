"""Offline portable Python/PDF compatibility test. Never edits the main app."""
from __future__ import annotations

import argparse
import contextlib
import ctypes
import datetime as dt
import hashlib
import html
import json
import logging
import os
from pathlib import Path
import platform
import re
import sys
import warnings
import zlib

VERSION = "1.0.0"
PYTHON_VERSION = "3.14.10"
PYPDF_VERSION = "7.0.1"
BASIC = ["Homogeneity / Water", "Noise"]
EXTENDED = ["Lightmarker", "External Lightm.", "Sag./Cor. Lightm.",
            "Topogram Pos.", "Slice", *BASIC, "MTF", "Contrast", "Table Position"]
FOOTER = re.compile(r"(?m)^\s*(\d{4}-\d{2}-\d{2})[ \t]+(\d{2}:\d{2}:\d{2})[ \t\r\n|]*Page\s*:\s*(\d+)\s*/\s*(\d+)\s*$")
HEADING = re.compile(r"(?im)^[ \t]*(\d{1,2})\.[ \t\r\n]*Quality\s+IEC\s+Constancy[ \t]*(?:\r?\n[ \t]*)?([^\r\n]+?)[ \t]*$")
OUTCOME = re.compile(r"(?im)(?<!\S)(NOT[ \t]+OK|OK|FAIL(?:ED)?|PASS(?:ED)?|ERROR|WARNING|NOT[ \t]+EVALUATED)[ \t]*$")


def make_pdf(page_lines: list[list[str]]) -> bytes:
    """Generate deterministic text PDFs using a standard font and Flate streams."""
    objects = [b"", b"", b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    page_ids = []
    for lines in page_lines:
        page_id = len(objects) + 1
        stream_id = page_id + 1
        page_ids.append(page_id)
        objects.append((f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents {stream_id} 0 R >>").encode())
        escaped = [line.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)") for line in lines]
        stream = ("BT /F1 10 Tf 14 TL 36 760 Td\n" + "\n".join("(" + line + ") Tj T*" for line in escaped) + "\nET").encode("ascii")
        compressed = zlib.compress(stream)
        objects.append(f"<< /Length {len(compressed)} /Filter /FlateDecode >>\nstream\n".encode() + compressed + b"\nendstream")
    objects[0] = b"<< /Type /Catalog /Pages 2 0 R >>"
    objects[1] = (f"<< /Type /Pages /Count {len(page_ids)} /Kids [" + " ".join(f"{n} 0 R" for n in page_ids) + "] >>").encode()
    data = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for number, body in enumerate(objects, 1):
        offsets.append(len(data))
        data.extend(f"{number} 0 obj\n".encode() + body + b"\nendobj\n")
    start = len(data)
    data.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        data.extend(f"{offset:010d} 00000 n \n".encode())
    data.extend(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n".encode())
    return bytes(data)


def fixture_bytes() -> dict[str, bytes]:
    answer = {}
    for profile, sections, count, date, time in [
        ("Basic", BASIC, 3, "2026-01-06", "07:08:00"),
        ("Extended", EXTENDED, 5, "2026-01-01", "07:21:54"),
    ]:
        pages = [["SYNTHETIC TEST DOCUMENT - NO PATIENT DATA", "SOMATOM Definition Edge", "Quality IEC Constancy", "Handed over: 2014-03-15", "Last reference measurement: 2020-02-12"],
                 ["SYNTHETIC TABLE OF CONTENTS", *[f"{n}. {s}" for n, s in enumerate(sections, 1)]]]
        body_pages = [[] for _ in range(count - 2)]
        for n, section in enumerate(sections, 1):
            target = min((n - 1) * len(body_pages) // len(sections), len(body_pages) - 1)
            body_pages[target].extend([f"{n}. Quality IEC Constancy", section, "Printed observation OK", ""])
        pages.extend(body_pages)
        for n, lines in enumerate(pages, 1):
            lines.extend([f"{date} {time}", f"Page: {n} / {count}"])
        answer["fixture-" + profile.lower() + ".pdf"] = make_pdf(pages)
    return answer


def is_below(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except (ValueError, OSError):
        return False


def check_manifest(root: Path) -> bool:
    """Check package consistency; this is not a publisher signature."""
    try:
        expected = {}
        for line in (root / "Package-SHA256SUMS.txt").read_text(encoding="utf-8").splitlines():
            digest, name = line.split("  ", 1)
            parts = Path(name).parts
            if not re.fullmatch(r"[0-9a-f]{64}", digest) or not name or "\\" in name or ":" in name or Path(name).is_absolute() or ".." in parts or parts[0] == "Results" or name in expected:
                return False
            path = root / name
            if path.is_symlink() or not is_below(path, root) or not path.is_file():
                return False
            current = path
            while current != root:
                if current.is_symlink() or getattr(current, "is_junction", lambda: False)():
                    return False
                current = current.parent
            if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                return False
            expected[name] = digest
        actual = {p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file() and p.relative_to(root).parts[0] != "Results" and p.relative_to(root).as_posix() != "Package-SHA256SUMS.txt"}
        return bool(expected) and actual == set(expected)
    except (OSError, ValueError, UnicodeError):
        return False


class QuietOutput:
    def write(self, value):
        return len(value)

    def flush(self):
        pass


def empty_pdf_result(selected: bool = True) -> dict:
    return {"selected": selected, "readable": False, "status": "ReadError", "pages": 0, "readPages": 0, "profile": "Unknown", "dateStatus": "Missing", "sectionCount": 0, "printedObservationCount": 0, "needsOCR": False}


def read_pdf(path: Path, *, include_date: bool = False) -> dict:
    result = empty_pdf_result()
    try:
        if not path.is_file() or path.is_symlink() or path.stat().st_size > 30 * 1024 * 1024:
            result["status"] = "FileUnavailableOrTooLarge"
            return result
        from pypdf import PdfReader
        with contextlib.redirect_stdout(QuietOutput()), contextlib.redirect_stderr(QuietOutput()):
            with path.open("rb") as handle:
                reader = PdfReader(handle, strict=True)
                if reader.is_encrypted:
                    result["status"] = "UnsupportedEncrypted"
                    return result
                count = len(reader.pages)
                result["pages"] = count
                if not 0 < count <= 100:
                    result["status"] = "PageLimit"
                    return result
                pages = []
                characters = 0
                for page in reader.pages:
                    text = (page.extract_text() or "").replace("\r\n", "\n").replace("\r", "\n").replace("\u00a0", " ")
                    characters += len(text)
                    if characters > 1_000_000:
                        result["status"] = "TextLimit"
                        return result
                    pages.append(text)
                    result["readPages"] += 1
        if not any(t.strip() for t in pages):
            result.update(status="NeedsOCR", needsOCR=True)
            return result
        footers = []
        date_status = "Consensus"
        for number, text in enumerate(pages, 1):
            matches = FOOTER.findall(text)
            if len(matches) != 1:
                date_status = "Missing" if len(matches) == 0 else "Conflict"
                break
            date, time, printed_number, printed_total = matches[0]
            try:
                dt.datetime.strptime(date + " " + time, "%Y-%m-%d %H:%M:%S")
            except ValueError:
                date_status = "Invalid"
                break
            if int(printed_number) != number or int(printed_total) != count:
                date_status = "Conflict"
                break
            footers.append(date + " " + time)
        if len(set(footers)) > 1:
            date_status = "Conflict"
        body = "\n".join(pages[2:])
        headings = [(int(m.group(1)), re.sub(r"\s+", " ", m.group(2)).strip()) for m in HEADING.finditer(body)]
        labels = [s for _, s in headings]
        ordered = [n for n, _ in headings] == list(range(1, len(headings) + 1))
        supported = bool(re.search(r"(?i)\bSOMATOM\s+Definition\s+Edge\b", "\n".join(pages))) and bool(re.search(r"(?i)Quality\s+IEC\s+Constancy", body))
        profile = "Basic" if supported and ordered and labels == BASIC else "Extended" if supported and ordered and labels == EXTENDED else "Unknown"
        result.update(readable=True, status="Read", profile=profile, dateStatus=date_status, sectionCount=len(headings), printedObservationCount=len(OUTCOME.findall(body)))
        if include_date:
            result["date"] = footers[0][:10] if date_status == "Consensus" and len(footers) == count else ""
        return result
    except Exception:
        # No library exception message, selected path, document text or filename is logged.
        return result


def render_html(result: dict) -> str:
    passed = result["totals"]["failed"] == 0
    heading = "PASS - Portable Python checks passed" if passed else "ATTENTION - A compatibility check failed"
    rows = "".join("<tr><td>" + html.escape(row["label"]) + "</td><td class='" + ("good" if row["status"] == "PASS" else "bad") + "'>" + row["status"] + "</td></tr>" for row in result["checks"])
    fixtures = "".join("<li>" + html.escape(row["profile"]) + ": " + str(row["readPages"]) + "/" + str(row["pages"]) + " pages read; " + str(row["sectionCount"]) + " test sections.</li>" for row in result["fixtures"])
    optional = result["optionalPdf"]
    selected = ("<p>Status: <b>" + html.escape(optional["status"]) + "</b>. " + str(optional["readPages"]) + " pages read. Recognized layout: " + html.escape(optional["profile"]) + ".</p>") if optional["selected"] else "<p>To try one of your own reports, drag a PDF onto <b>Run Python Test.cmd</b>. Only summary counts are saved.</p>"
    runtime = result["runtime"]
    return """<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Portable Python test</title><style>body{font:16px/1.6 Segoe UI,Arial,sans-serif;background:#edf5f3;color:#173b40;max-width:850px;margin:40px auto;padding:20px}section{background:white;padding:24px;border:1px solid #d4e3df;border-radius:14px;margin:18px 0}h1{font-size:28px}.good{color:#087969;font-weight:bold}.bad{color:#b33d27;font-weight:bold}table{border-collapse:collapse;width:100%}td{padding:10px 4px;border-bottom:1px solid #e3ece8}.muted{color:#536e71;font-size:14px}code{background:#e9f3ef;padding:3px 6px}</style><p class="muted">CT QA / SEPARATE COMPATIBILITY TEST</p><h1>""" + heading + "</h1><p>This test checks the bundled Python runtime and PDF reader. It makes no changes to CT QA Manager.</p><section><h2>Compatibility checks</h2><table>" + rows + "</table><p class='muted'>Python " + html.escape(runtime["version"]) + "; PDF reader " + html.escape(runtime["pypdfVersion"]) + ". Elevated Windows token: " + ("Yes" if runtime["adminTokenDetected"] else "No" if runtime["adminTokenDetected"] is False else "Not detected") + ".</p></section><section><h2>Built-in example reports</h2><ul>" + fixtures + "</ul><p class='muted'>These examples contain generated test data. Layout detection does not decide whether your department calls a report Daily or Monthly.</p></section><section><h2>Your optional PDF</h2>" + selected + "<p class='muted'>Its contents, name, location and dates are excluded from the saved summary. Image-only PDFs need OCR; encrypted PDFs are outside this small test.</p></section><section><h2>What this result means</h2><p>A pass demonstrates this portable bundle ran on this computer and read the built-in text PDFs. You can run the same test on the work computer later to check its application restrictions.</p><p>The Python process blocks socket operations during the test. This checks our application guard; it does not change or test your workplace firewall policy.</p><p class='muted'>Keep this folder together. Results are saved as <code>Results/ProbeResult.json</code> and this HTML page. Share the JSON summary for troubleshooting; it contains fixed test outcomes and counts.</p></section></html>"


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError("Unsupported test arguments")


def main() -> int:
    parser = SafeArgumentParser(prog="Portable Python Test", description="Offline portable Python compatibility test")
    parser.add_argument("--no-open", action="store_true")
    parser.add_argument("--pdf", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    logging.disable(logging.CRITICAL)
    warnings.filterwarnings("ignore")
    checks = []

    def check(identifier, label, condition, details=None):
        checks.append({"id": identifier, "label": label, "status": "PASS" if condition else "FAIL", "details": details or {}})

    blocked = [0]

    def audit(event, values):
        if event.startswith("socket."):
            blocked[0] += 1
            raise PermissionError("Network operation blocked by portable test")

    sys.addaudithook(audit)
    try:
        import socket
        socket.socket()
        guard_ok = False
    except PermissionError:
        guard_ok = True
    check("NetworkAuditGuard", "Python network guard blocks socket operations", guard_ok, {"socketCallsBlocked": blocked[0], "externalNetworkContactAttempted": False, "scope": "InProcessPythonGuard"})
    integrity = check_manifest(root)
    check("ManifestIntegrity", "Bundled files match the package manifest", integrity)
    windows = os.name == "nt"
    admin = None
    if windows:
        try:
            admin = bool(ctypes.windll.shell32.IsUserAnAdmin())
        except Exception:
            pass
    version = platform.python_version()
    arch = platform.machine().upper()
    if arch not in {"AMD64", "X86_64", "ARM64", "X86", "I386", "I686"}:
        arch = "Unknown"
    runtime = {"version": version, "embeddedExeInBundle": is_below(Path(sys.executable), root / "runtime"), "isolated": bool(sys.flags.isolated), "noSite": bool(sys.flags.no_site), "noUserSite": bool(sys.flags.no_user_site), "dontWriteBytecode": bool(sys.flags.dont_write_bytecode), "pypdfVersion": "Unavailable", "pypdfInBundle": False, "adminTokenDetected": admin, "windows": windows, "processorArchitecture": arch, "windowsVersion": {}}
    if windows:
        info = sys.getwindowsversion()
        runtime["windowsVersion"] = {"major": info.major, "minor": info.minor, "build": info.build}
    check("EmbeddedRuntime", "Python runs from the included runtime", windows and runtime["embeddedExeInBundle"] and version == PYTHON_VERSION)
    check("IsolatedRuntime", "Installed Python and environment imports are isolated", all(runtime[k] for k in ["isolated", "noSite", "noUserSite", "dontWriteBytecode"]))
    if integrity:
        try:
            import pypdf
            runtime["pypdfVersion"] = pypdf.__version__
            runtime["pypdfInBundle"] = is_below(Path(pypdf.__file__), root / "vendor")
        except Exception:
            pass
    check("BundledPdfReader", "PDF reader loads from the included files", runtime["pypdfVersion"] == PYPDF_VERSION and runtime["pypdfInBundle"])
    output = root / "Results"
    write_ok = False
    try:
        if output.exists() and (output.is_symlink() or getattr(output, "is_junction", lambda: False)()):
            raise OSError("Linked output folder")
        output.mkdir(exist_ok=True)
        sentinel = output / ".write-check"
        if sentinel.exists() or sentinel.is_symlink():
            raise OSError("Occupied output sentinel")
        sentinel.write_bytes(b"portable-folder-write-test")
        write_ok = sentinel.read_bytes() == b"portable-folder-write-test"
        sentinel.unlink()
    except OSError:
        pass
    check("FolderWrite", "Results can be saved inside this portable folder", write_ok)
    fixtures = []
    if integrity and runtime["pypdfInBundle"]:
        for profile, pages, date, sections in [("Basic", 3, "2026-01-06", 2), ("Extended", 5, "2026-01-01", 10)]:
            fixture = read_pdf(root / "Fixtures" / ("fixture-" + profile.lower() + ".pdf"), include_date=True)
            fixtures.append(fixture)
            check("Pdf" + profile, "Read " + profile.lower() + " example and recognize its sections/date", fixture["readable"] and fixture["pages"] == pages and fixture["readPages"] == pages and fixture["profile"] == profile and fixture["dateStatus"] == "Consensus" and fixture.get("date") == date and fixture["sectionCount"] == sections and fixture["printedObservationCount"] == sections, {"pages": fixture["pages"], "sectionCount": fixture["sectionCount"]})
    else:
        check("PdfBasic", "Read basic example and recognize its sections/date", False)
        check("PdfExtended", "Read extended example and recognize its sections/date", False)
    optional = empty_pdf_result(selected=False)
    if args.pdf is not None:
        if integrity and runtime["pypdfInBundle"]:
            optional = read_pdf(args.pdf)
        else:
            optional = empty_pdf_result()
            optional["status"] = "DependencyUnavailable"
    failed = sum(row["status"] != "PASS" for row in checks)
    result = {"schemaVersion": 1, "product": "CT QA Portable Python Test", "version": VERSION, "overall": "PASS" if not failed else "FAIL", "runtime": runtime, "checks": checks, "fixtures": fixtures, "optionalPdf": optional, "totals": {"tests": len(checks), "passed": len(checks) - failed, "failed": failed}, "privacy": "Fixed test outcomes and counts. No selected PDF text, names, paths, dates, usernames, network addresses or credentials are included. No original PDF is changed or copied.", "mainApplicationChanged": False}
    if write_ok:
        try:
            for name in ["ProbeResult.json", "ProbeResult.html"]:
                target = output / name
                if target.is_symlink() or getattr(target, "is_junction", lambda: False)():
                    raise OSError("Linked result file")
            (output / "ProbeResult.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
            (output / "ProbeResult.html").write_text(render_html(result), encoding="utf-8")
            if windows and not args.no_open:
                os.startfile(output / "ProbeResult.html")
        except OSError:
            print("Results could not be saved or opened. Keep the test in a writable local folder.")
            return 1
    print("Portable Python test: " + result["overall"] + ". " + str(len(checks) - failed) + "/" + str(len(checks)) + " checks passed.")
    if write_ok:
        print("Open Results/ProbeResult.html for the summary.")
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        exit_code = main()
    except KeyboardInterrupt:
        print("Portable Python test cancelled.")
        exit_code = 130
    except Exception:
        print("Portable Python test could not complete. Extract the complete test folder and run it from a writable local location.")
        exit_code = 1
    raise SystemExit(exit_code)
