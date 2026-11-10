PORTABLE PDF TEXT READER COMPONENTS

PdfPig 0.1.16, unmodified net471 runtime assemblies.
Source: https://github.com/UglyToad/PdfPig
Package: https://www.nuget.org/packages/PdfPig/0.1.16
Source commit: a7bb35662bbbf405efddad50aedc9bcdcf515afc
NuGet package SHA-256: d67171846ea8c28f50359137065fec4514266d7a32b23eae6c5f2ebed8ffcfc4
License: Apache-2.0. See LICENSE-PdfPig.txt and NOTICES-PdfPig.txt.

Microsoft dependencies (MIT): Microsoft.Bcl.HashCode 6.0.0,
System.Memory 4.6.0, System.Buffers 4.6.0, System.Numerics.Vectors 4.6.0,
System.Runtime.CompilerServices.Unsafe 6.1.0.
Source: https://github.com/dotnet/maintenance-packages
Packages downloaded from the official api.nuget.org v3 flat container.
See LICENSE-Microsoft.txt. Per-DLL checksums are in Integrity.json.

Windows PDF text reading requires .NET Framework 4.7.2 or newer. The application
never installs or downloads a runtime. Text reading is optional; the other
archive functions remain usable if hospital policy blocks these components.
Native Windows loading still needs acceptance testing on the actual workstation.

The reader extracts existing text locally. It does not perform OCR, execute
PDF scripts, send reports to AI/cloud services, or confirm QA classifications.
The time/cancel checks are cooperative between parser calls and pages; an
individual parser call cannot be forcibly interrupted.
