# pwsh-distro

GitHub Actions workflows for building redistributable PowerShell artifacts from upstream source. The primary target is a single vendored `Devolutions.PowerShell.SDK` package, and the secondary target is a self-contained PowerShell distribution archive.

## Current pins

| Component | Version |
| --- | --- |
| PowerShell | `7.6.3` / `v7.6.3` |
| PowerShell target framework | `net10.0` |
| PowerShell SDK package ID | `Devolutions.PowerShell.SDK` |
| .NET runtime workflow | `v10.0.5` |
| llvm-prebuilt | `v2026.1.1` |
| clang+llvm | `22.1.4` |
| VsDevShell | `2026.1.0` / `9b4518e6c45a2abedbf6a05b77c9912aaef70f1e` |

## Workflows

| Workflow | Purpose | Output |
| --- | --- | --- |
| `.github/workflows/powershell-sdk.yml` | Builds PowerShell from source, vendors the source-built PowerShell SDK assemblies into one `Devolutions.PowerShell.SDK` package, and validates it in a sample .NET app with opt-in apphost import. | `PowerShell-SDK-7.6.3` artifact containing one `.nupkg`. |
| `.github/workflows/powershell.yml` | Builds self-contained PowerShell archives for Windows, macOS, and Linux on x64 and arm64. | `PowerShell-7.6.3-<os>-<arch>` `.tar.gz` artifacts. |
| `.github/workflows/dotnet-runtime.yml` | Builds the .NET runtime tag used by this PowerShell release for Windows, macOS, and Linux on x86_64 and arm64 with prebuilt clang+llvm from `awakecoding/llvm-prebuilt`. | Runtime build output in the workflow logs/workspace. |

All workflows are manual and can be started from the GitHub Actions **Run workflow** button.

## Notes

The SDK workflow intentionally derives the target framework from upstream `PowerShell.Common.props` instead of hardcoding it, so future PowerShell updates only need the version pins refreshed. The SDK package is assembled from locally built PowerShell binaries plus package layouts from the official NuGet packages for the same PowerShell version, then `eng/Vendor-PowerShellSdkPackage.ps1` rewrites the NuGet package ID and vendor metadata to Devolutions.

The package keeps original assembly identities (`System.Management.Automation.dll`, `Microsoft.PowerShell.Commands.Utility.dll`, and related assemblies) so consumers only need to change the NuGet package reference. Source-built PowerShell assemblies are embedded directly in `Devolutions.PowerShell.SDK`, so validation fails if original source-built package IDs such as `Microsoft.PowerShell.SDK` or `System.Management.Automation` appear in the restore graph. External packages that are not built by this repository, including `Microsoft.PowerShell.Native` and `Microsoft.PowerShell.MarkdownRender`, remain normal public NuGet dependencies.

The SDK package also includes source-built apphost files for `win-x64`, `linux-x64`, `linux-arm64`, `osx-x64`, and `osx-arm64`. These files are inert by default. A consuming project can copy the matching `pwsh`/`pwsh.exe`, `pwsh.dll`, `pwsh.runtimeconfig.json`, and the matching built-in module manifests into its output by setting:

```xml
<PropertyGroup>
  <PowerShellSDKIncludeAppHost>true</PowerShellSDKIncludeAppHost>
</PropertyGroup>
```

The package selects `$(RuntimeIdentifier)` first, then falls back to the SDK host runtime identifier. Set `PowerShellSDKAppHostRuntimeIdentifier` to override that selection explicitly. Unsupported runtime identifiers fail the build with a clear error instead of silently omitting apphost files. The apphost output is intended for running scripts with the core built-in modules from `$PSHOME/Modules`; it is not a full PowerShell distribution archive with localized resources, help content, or optional gallery modules.

Generated source checkouts and build artifacts are not part of this repository.
