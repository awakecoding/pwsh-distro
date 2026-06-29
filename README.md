# pwsh-distro

GitHub Actions workflows for building redistributable PowerShell artifacts from upstream or downstream-patched source. The primary target is a single vendored `Devolutions.PowerShell.SDK` package, and the secondary target is a self-contained PowerShell distribution archive.

## Quick start

This repository builds PowerShell from source. The full PowerShell source tree is pulled in as a git submodule at `pwsh-src/`, so the checkout must initialize submodules, and on Windows it requires long-path support enabled in git.

```powershell
git clone https://github.com/awakecoding/pwsh-distro.git
cd pwsh-distro
.\scripts\Initialize-Repository.ps1
```

All workflows are manual and start from the GitHub Actions **Run workflow** button (see the Workflows table below). The workflows are the authoritative release builds.

> On Linux/macOS no long-path configuration is needed. On Windows, if `core.longpaths` is not enabled, the `pwsh-src` submodule checkout will fail with `Filename too long`. `scripts\Initialize-Repository.ps1` enables it before initializing the submodule. The workflows set this on their Windows runners automatically.

To build a local, current-RID SDK package for smoke testing outside Actions:

```powershell
.\scripts\Build-LocalPowerShellSdk.ps1 -Validate
```

The local script writes under `output\local-sdk\<rid>\` and produces a single-RID validation package. The GitHub Actions SDK workflow remains the authoritative multi-RID package build.

## Current pins

| Component | Version |
| --- | --- |
| PowerShell upstream release | `7.6.3` / `v7.6.3` |
| PowerShell downstream source ref | `downstream/v7.6.3` based on `upstream/v7.6.3` |
| PowerShell target framework | `net10.0` |
| PowerShell SDK package ID | `Devolutions.PowerShell.SDK` |
| multi-pwsh apphost package | `Devolutions.MultiPwsh.Cli` / `0.14.0` |
| multi-pwsh apphost package source | `https://api.nuget.org/v3/index.json` |
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

## Branching model

This repository follows a downstream patch branch model inspired by `Devolutions/gsudo-distro`: `master` stays downstream-only, upstream PowerShell refs are mirrored under `upstream/*`, and source patches live on `downstream/vX.Y.Z` branches based on upstream release tags. The patched source is exposed on `master` as a same-repo submodule at `pwsh-src/` pinned to a commit on `downstream/vX.Y.Z`, so workflows build the exact reviewed source tree with a single `actions/checkout` using `submodules: true`. See [BRANCHING.md](BRANCHING.md) for the full branch, tag, submodule, and worktree flow.

## Updating PowerShell versions

When moving to a new upstream PowerShell release, the bump touches four surfaces in the same PR:

1. Workflow `env` blocks in `.github/workflows/powershell-sdk.yml` and `.github/workflows/powershell.yml`: `POWERSHELL_VERSION`, `POWERSHELL_RELEASE_TAG`, `POWERSHELL_UPSTREAM_TAG`, and `POWERSHELL_SOURCE_REF`.
2. `.gitmodules`: the `branch = downstream/vX.Y.Z` line under `[submodule "pwsh-src"]` (git does not expand variables in `.gitmodules`, so this must be edited literally).
3. The `pwsh-src` submodule pointer on `master`, bumped to the new `downstream/vX.Y.Z` tip with `git submodule update --remote pwsh-src && git add pwsh-src`.
4. The "Current pins" table above.

Verify the upstream target framework from `pwsh-src/PowerShell.Common.props` after the bump and keep SDK packaging paths derived from that property instead of hardcoding `net*` folders.

## Notes

The PowerShell workflows check out this repository with `submodules: true` to populate `pwsh-src/` from the pinned submodule commit on `downstream/vX.Y.Z`, while build metadata continues to use `POWERSHELL_RELEASE_TAG`. This allows downstream patch branches to be built without passing branch names to PowerShell build steps that expect upstream release tags. `POWERSHELL_SOURCE_REF` documents which patch branch the submodule tracks; bumping the submodule pointer on `master` is what actually moves the built source.

The SDK workflow intentionally derives the target framework from upstream `PowerShell.Common.props` instead of hardcoding it, so future PowerShell updates only need the version pins refreshed. The SDK package is assembled from locally built PowerShell binaries plus package layouts from the official NuGet packages for the same PowerShell version, then `eng/Vendor-PowerShellSdkPackage.ps1` rewrites the NuGet package ID and vendor metadata to Devolutions.

The package keeps original assembly identities (`System.Management.Automation.dll`, `Microsoft.PowerShell.Commands.Utility.dll`, and related assemblies) so consumers only need to change the NuGet package reference. Source-built PowerShell assemblies are embedded directly in `Devolutions.PowerShell.SDK`, so validation fails if original source-built package IDs such as `Microsoft.PowerShell.SDK` or `System.Management.Automation` appear in the restore graph. External packages that are not built by this repository, including `Microsoft.PowerShell.Native` and `Microsoft.PowerShell.MarkdownRender`, remain normal public NuGet dependencies.

The SDK package also includes apphost files for `win-x64`, `linux-x64`, `linux-arm64`, `osx-x64`, and `osx-arm64`. The root apphost mode uses the native `pwsh`/`pwsh.exe` launcher staged from the public `Devolutions.MultiPwsh.Cli` build-time package on NuGet.org; `pwsh.dll`, `pwsh.runtimeconfig.json`, runtime assemblies, and modules remain source-built by this repository. These files are inert by default. A consuming project can copy the matching `pwsh`/`pwsh.exe`, `pwsh.dll`, `pwsh.runtimeconfig.json`, and the matching built-in module manifests into its output by setting:

```xml
<PropertyGroup>
  <PowerShellSDKIncludeAppHost>true</PowerShellSDKIncludeAppHost>
</PropertyGroup>
```

The package selects `$(RuntimeIdentifier)` first, then falls back to the SDK host runtime identifier. Set `PowerShellSDKAppHostRuntimeIdentifier` to override that selection explicitly. Unsupported runtime identifiers fail the build with a clear error instead of silently omitting apphost files. The apphost output is intended for running scripts with the core built-in modules from `$PSHOME/Modules`; it is not a full PowerShell distribution archive with localized resources, help content, or optional PSGallery modules.

For applications that need architecture-specific apphost launchers in a native asset layout, opt in to runtime-native apphost output:

```xml
<PropertyGroup>
  <PowerShellSDKIncludeRuntimeNativeAppHosts>true</PowerShellSDKIncludeRuntimeNativeAppHosts>
  <PowerShellSDKRuntimeNativeAppHostRuntimeIdentifiers>win-x64;win-arm64</PowerShellSDKRuntimeNativeAppHostRuntimeIdentifiers>
</PropertyGroup>
```

This copies a minimal native launcher to `runtimes/<rid>/native/pwsh.exe` (or `pwsh` on Unix) for each selected RID. The launcher is patched to load `../../../pwsh.dll`, so `pwsh.dll`, `pwsh.runtimeconfig.json`, PowerShell runtime assemblies, built-in modules, and required RID-specific runtime library dependencies are copied once to the app output root and shared with the consuming executable. Leave `PowerShellSDKRuntimeNativeAppHostRuntimeIdentifiers` empty to copy every runtime-native launcher included in the package, or set it to a semicolon-delimited RID list. Set `PowerShellSDKRuntimeNativeSharedPayloadRuntimeIdentifier` to override the app-root payload RID; otherwise it follows `$(RuntimeIdentifier)`, `$(NETCoreSdkRuntimeIdentifier)`, or the root apphost override. Shared payload lookup normalizes platform-specific TFMs such as `net10.0-windows10.0.19041` to the package TFM `net10.0`; set `PowerShellSDKRuntimeNativeSharedPayloadTargetFramework` only if an explicit package payload TFM override is needed. Set `PowerShellSDKRuntimeNativeAppHostCopyToOutput` or `PowerShellSDKRuntimeNativeAppHostCopyToPublish` to `false` to disable one copy phase.

The SDK package also stages the optional PSGallery modules that upstream PowerShell bundles into full distribution archives. They are separate from the core built-in module payload and are inert by default. To copy all staged PSGallery modules to the app or publish root `Modules` directory, opt in explicitly:

```xml
<PropertyGroup>
  <PowerShellSDKIncludePSGalleryModules>true</PowerShellSDKIncludePSGalleryModules>
</PropertyGroup>
```

Set `PowerShellSDKPSGalleryModuleNames` to a semicolon-delimited subset such as `Microsoft.PowerShell.Archive;Microsoft.PowerShell.ThreadJob` when a consumer does not need every staged PSGallery module. Set `PowerShellSDKPSGalleryModulesCopyToOutput` or `PowerShellSDKPSGalleryModulesCopyToPublish` to `false` to disable one copy phase. PSGallery modules increase package and output size, include additional package-management or interactive functionality, and several are script modules subject to the host machine's PowerShell execution policy, so consumers should enable them deliberately and launch `pwsh` with an appropriate policy strategy when needed.

During NuGet packing, upstream `Microsoft.PowerShell.SDK` content file/reference metadata can emit NU5100/NU5131 package analysis warnings. The SDK workflow treats package validation as the source of truth: the generated sample must restore only the vendored PowerShell package ID, build, publish framework-dependent and self-contained outputs, execute `pwsh`, and load copied built-in modules.

Generated source checkouts and build artifacts are not part of this repository.
