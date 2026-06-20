# Agent instructions

This repository is a small GitHub Actions project for building PowerShell distribution artifacts. Treat `.github/workflows/powershell-sdk.yml` as the primary product surface and `.github/workflows/powershell.yml` as the secondary product surface.

Keep version pins explicit in workflow `env` blocks. When updating PowerShell, update the PowerShell version, release tag, upstream tag, and source ref in both PowerShell workflows, verify the upstream target framework from `PowerShell.Common.props`, and keep SDK packaging paths derived from that property instead of hardcoding `net*` folders.

The repository uses a downstream patch branch model:

- `master` is downstream-only and must not contain the upstream PowerShell source tree.
- `upstream` mirrors `PowerShell/PowerShell` for traceability.
- `upstream/vX.Y.Z` mirrors upstream PowerShell release tags.
- `release/vX.Y.Z` branches contain full PowerShell sources plus downstream patches.
- Downstream release tags use `vX.Y.Z.R`.

In PowerShell workflows, keep the source checkout ref separate from build version metadata. `POWERSHELL_SOURCE_REF` can point at `release/vX.Y.Z`, but `POWERSHELL_RELEASE_TAG` should remain the upstream release tag passed to PowerShell build logic.

The `.NET runtime` workflow uses `awakecoding/llvm-prebuilt` assets. When refreshing it, verify the release tag and required `clang+llvm-<version>-x86_64-<platform>.tar.xz` assets exist before changing `CLANG_LLVM_VERSION`, `CLANG_LLVM_RELEASE`, or runner OS labels.

Do not commit generated `PowerShell/`, `dotnet-runtime/`, package, archive, or build output directories. Prefer validating workflow edits with a YAML parser and `git diff --check` before finishing.
