# pwsh-distro

GitHub Actions workflows for building redistributable PowerShell artifacts from upstream source. The primary target is a refreshed `Microsoft.PowerShell.SDK` package, and the secondary target is a self-contained PowerShell distribution archive.

## Current pins

| Component | Version |
| --- | --- |
| PowerShell | `7.6.3` / `v7.6.3` |
| PowerShell target framework | `net10.0` |
| .NET runtime workflow | `v10.0.5` |
| llvm-prebuilt | `v2026.1.1` |
| clang+llvm | `22.1.4` |
| VsDevShell | `2026.1.0` / `9b4518e6c45a2abedbf6a05b77c9912aaef70f1e` |

## Workflows

| Workflow | Purpose | Output |
| --- | --- | --- |
| `.github/workflows/powershell-sdk.yml` | Builds PowerShell from source and repacks `Microsoft.PowerShell.SDK` for the upstream target framework. | `PowerShell-SDK-7.6.3` artifact containing a `.nupkg`. |
| `.github/workflows/powershell.yml` | Builds self-contained PowerShell archives for Windows, macOS, and Linux on x64 and arm64. | `PowerShell-7.6.3-<os>-<arch>` `.tar.gz` artifacts. |
| `.github/workflows/dotnet-runtime.yml` | Builds the .NET runtime tag used by this PowerShell release for Windows, macOS, and Linux on x86_64 and arm64 with prebuilt clang+llvm from `awakecoding/llvm-prebuilt`. | Runtime build output in the workflow logs/workspace. |

All workflows are manual and can be started from the GitHub Actions **Run workflow** button.

## Notes

The SDK workflow intentionally derives the target framework from upstream `PowerShell.Common.props` instead of hardcoding it, so future PowerShell updates only need the version pins refreshed. The SDK package is assembled from the locally built SDK binaries plus metadata, reference assemblies, and content layout from the official NuGet package for the same PowerShell version.

Generated source checkouts and build artifacts are not part of this repository.
