"""Private pipe-only PDF reading worker for the bundled portable interpreter.

Input: little-endian uint32 JSON-header length, header, then the exact PDF bytes.
Output: one JSON response. No file paths, filenames or raw errors are accepted or
printed. Extracted text is returned only through the parent's private pipe.
"""
from __future__ import annotations

import contextlib
import hashlib
import io
import json
import logging
from pathlib import Path
import struct
import sys
import time
import warnings

SCHEMA_VERSION = 1
PYPDF_VERSION = "7.0.1"
MAXIMUM_BYTES = 104857600
MAXIMUM_HEADER = 65536
HEADER_FIELDS = {"schemaVersion", "length", "maximumPages", "maximumCharacters", "maximumSeconds"}


class InputError(Exception):
    pass


class ReaderUnavailable(Exception):
    pass


class QuietOutput:
    def write(self, value):
        return len(value)

    def flush(self):
        pass


def is_below(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except (ValueError, OSError):
        return False


def deny_network(event, arguments):
    if event.startswith("socket."):
        raise PermissionError("Network operations are unavailable in this reader")


def read_exact(stream, count: int) -> bytes:
    parts = []
    remaining = count
    while remaining:
        block = stream.read(min(remaining, 1048576))
        if not block:
            raise InputError()
        parts.append(block)
        remaining -= len(block)
    return b"".join(parts)


def read_request(stream) -> tuple[dict, bytes]:
    header_size = struct.unpack("<I", read_exact(stream, 4))[0]
    if not 1 <= header_size <= MAXIMUM_HEADER:
        raise InputError()
    try:
        header = json.loads(read_exact(stream, header_size).decode("utf-8"))
    except (ValueError, UnicodeError):
        raise InputError() from None
    if not isinstance(header, dict) or set(header) != HEADER_FIELDS:
        raise InputError()
    if any(type(header[name]) is not int for name in HEADER_FIELDS):
        raise InputError()
    if header["schemaVersion"] != SCHEMA_VERSION:
        raise InputError()
    if not 1 <= header["length"] <= MAXIMUM_BYTES:
        raise InputError()
    if not 1 <= header["maximumPages"] <= 1000:
        raise InputError()
    if not 500 <= header["maximumCharacters"] <= 2000000:
        raise InputError()
    if not 5 <= header["maximumSeconds"] <= 120:
        raise InputError()
    data = read_exact(stream, header["length"])
    if stream.read(1):
        raise InputError()
    return header, data


def load_reader():
    # The parent has verified the complete runtime manifest before launch.
    # The ._pth file and -I -B -S flags isolate imports from installed Python.
    if not all((sys.flags.isolated, sys.flags.no_site, sys.flags.no_user_site, sys.flags.dont_write_bytecode)):
        raise ReaderUnavailable()
    import pypdf
    if pypdf.__version__ != PYPDF_VERSION or not is_below(Path(pypdf.__file__), Path(__file__).resolve().parent / "vendor"):
        raise ReaderUnavailable()
    # Bound the size of a single decoded Flate stream as well as the complete
    # input/text limits. The parent independently enforces a wall-clock timeout.
    pypdf.overwrite_configuration(zlib_maximum_output_length=20000000,
                                 disable_legacy_handling=True, jbig2dec_binary=None)
    return pypdf.PdfReader


def read_buffer(data: bytes, header: dict) -> dict:
    started = time.perf_counter()
    digest = hashlib.sha256(data).hexdigest().upper()
    PdfReader = load_reader()
    document = PdfReader(io.BytesIO(data), strict=True)
    if document.is_encrypted:
        raise ValueError()
    pages = len(document.pages)
    if pages < 1:
        raise ValueError()
    maximum_pages = header["maximumPages"]
    maximum_characters = header["maximumCharacters"]
    maximum_seconds = header["maximumSeconds"]
    truncated = pages > maximum_pages
    parts = []
    length = 0
    read_pages = 0
    any_visible_text = False
    for page_number in range(1, min(pages, maximum_pages) + 1):
        if time.perf_counter() - started > maximum_seconds:
            truncated = True
            break
        remaining = maximum_characters - length
        if remaining <= 50:
            truncated = True
            break
        text = document.pages[page_number - 1].extract_text() or ""
        # Avoid invalid lone Unicode surrogates in the cross-runtime response.
        # Such replacement makes the extraction incomplete for classification.
        clean_text = text.encode("utf-8", "replace").decode("utf-8")
        if clean_text != text:
            truncated = True
        text = clean_text.replace("\r\n", "\n").replace("\r", "\n")
        any_visible_text = any_visible_text or bool(text.strip())
        heading = f"--- Page {page_number} ---\r\n"
        allowance = remaining - len(heading) - 4
        if len(text) > allowance:
            parts.append(heading + text[:max(0, allowance)] + "\r\n\r\n")
            read_pages += 1
            truncated = True
            break
        part = heading + text + "\r\n\r\n"
        parts.append(part)
        length += len(part)
        read_pages += 1
    full_text = "".join(parts)
    version = ".".join(str(n) for n in sys.version_info[:3])
    return {
        "schemaVersion": SCHEMA_VERSION,
        "success": True,
        "hash": digest,
        "length": len(data),
        "pages": pages,
        "readPages": read_pages,
        "text": full_text,
        "truncated": truncated,
        "needsOCR": not any_visible_text,
        "engine": "Python",
        "readerVersion": f"Python {version} / pypdf {PYPDF_VERSION}",
        "readMilliseconds": round((time.perf_counter() - started) * 1000, 3),
    }


def failure(code: str) -> dict:
    return {"schemaVersion": SCHEMA_VERSION, "success": False, "error": code}


def run(stream) -> dict:
    logging.disable(logging.CRITICAL)
    warnings.filterwarnings("ignore")
    try:
        with contextlib.redirect_stdout(QuietOutput()), contextlib.redirect_stderr(QuietOutput()):
            header, data = read_request(stream)
            return read_buffer(data, header)
    except InputError:
        return failure("InvalidInput")
    except (MemoryError, OverflowError):
        return failure("LimitExceeded")
    except (ReaderUnavailable, ImportError):
        return failure("ReaderUnavailable")
    except Exception:
        return failure("UnsupportedPdf")


def main() -> int:
    sys.addaudithook(deny_network)
    response = run(sys.stdin.buffer)
    # ASCII JSON also makes the response independent of the Windows console's
    # code page. The response carries no unredacted exception strings.
    sys.stdout.buffer.write(json.dumps(response, ensure_ascii=True, separators=(",", ":")).encode("ascii"))
    sys.stdout.buffer.flush()
    return 0 if response["success"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyboardInterrupt, Exception):
        try:
            sys.stdout.buffer.write(b'{"schemaVersion":1,"success":false,"error":"ReaderUnavailable"}')
            sys.stdout.buffer.flush()
        except Exception:
            pass
        raise SystemExit(1) from None
