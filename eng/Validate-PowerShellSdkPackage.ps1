[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $PackageDirectory,

  [Parameter(Mandatory)]
  [string] $PowerShellVersion,

  [Parameter(Mandatory)]
  [string] $TargetFramework,

  [string] $RuntimeIdentifier
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-DefaultRuntimeIdentifier {
  $Architecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
    'X64' { 'x64'; break }
    'Arm64' { 'arm64'; break }
    default { throw "Unsupported architecture for PowerShell SDK apphost validation: $_" }
  }

  if ($IsWindows) {
    return "win-$Architecture"
  }
  if ($IsLinux) {
    return "linux-$Architecture"
  }
  if ($IsMacOS) {
    return "osx-$Architecture"
  }

  throw "Unsupported operating system for PowerShell SDK apphost validation"
}

function Invoke-DotNet {
  param(
    [Parameter(Mandatory)]
    [string[]] $Arguments
  )

  & dotnet @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "dotnet $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

function Add-ProjectProperty {
  param(
    [Parameter(Mandatory)]
    [xml] $Project,

    [Parameter(Mandatory)]
    [System.Xml.XmlElement] $PropertyGroup,

    [Parameter(Mandatory)]
    [string] $Name,

    [Parameter(Mandatory)]
    [string] $Value
  )

  $Element = $Project.CreateElement($Name)
  $Element.InnerText = $Value
  [void] $PropertyGroup.AppendChild($Element)
}

if (-not $RuntimeIdentifier) {
  $RuntimeIdentifier = Get-DefaultRuntimeIdentifier
}

$PackageDirectoryPath = (Resolve-Path -LiteralPath $PackageDirectory).Path
$Package = Get-ChildItem -LiteralPath $PackageDirectoryPath -Filter "Microsoft.PowerShell.SDK.$PowerShellVersion*.nupkg" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
if (-not $Package) {
  throw "Unable to find Microsoft.PowerShell.SDK.$PowerShellVersion nupkg in $PackageDirectoryPath"
}

$ExecutableName = if ($RuntimeIdentifier -like 'win-*') { 'pwsh.exe' } else { 'pwsh' }
$ExpectedPackageEntries = @(
  'buildTransitive/Microsoft.PowerShell.SDK.targets',
  "tools/apphost/$RuntimeIdentifier/$ExecutableName",
  "tools/apphost/$RuntimeIdentifier/pwsh.dll",
  "tools/apphost/$RuntimeIdentifier/pwsh.runtimeconfig.json"
)

Add-Type -AssemblyName System.IO.Compression.FileSystem
$Zip = [System.IO.Compression.ZipFile]::OpenRead($Package.FullName)
try {
  foreach ($EntryName in $ExpectedPackageEntries) {
    if (-not ($Zip.Entries | Where-Object FullName -EQ $EntryName)) {
      throw "SDK package is missing expected entry: $EntryName"
    }
  }
} finally {
  $Zip.Dispose()
}

$TempRoot = if ($Env:RUNNER_TEMP) { $Env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$ValidationRoot = Join-Path $TempRoot "powershell-sdk-validation-$([Guid]::NewGuid().ToString('N'))"
$SampleDirectory = Join-Path $ValidationRoot 'sample'
$PackagesDirectory = Join-Path $ValidationRoot 'packages'

New-Item $SampleDirectory -ItemType Directory -Force | Out-Null
New-Item $PackagesDirectory -ItemType Directory -Force | Out-Null

$PreviousNuGetPackages = $Env:NUGET_PACKAGES
$Env:NUGET_PACKAGES = $PackagesDirectory
$PreviousLocation = Get-Location

try {
  Push-Location $SampleDirectory

  Invoke-DotNet @('new', 'console', '--framework', $TargetFramework, '--no-restore')
  $ProjectPath = (Get-ChildItem -LiteralPath $SampleDirectory -Filter '*.csproj' | Select-Object -First 1).FullName
  if (-not $ProjectPath) {
    throw "No sample project was generated in $SampleDirectory"
  }

  $EscapedPackageDirectoryPath = [System.Security.SecurityElement]::Escape($PackageDirectoryPath)
  $NuGetConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="ci-nupkg" value="$EscapedPackageDirectoryPath" />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
  </packageSources>
  <packageSourceMapping>
    <packageSource key="ci-nupkg">
      <package pattern="Microsoft.PowerShell.SDK" />
    </packageSource>
    <packageSource key="nuget.org">
      <package pattern="*" />
    </packageSource>
  </packageSourceMapping>
</configuration>
"@
  Set-Content -Path (Join-Path $SampleDirectory 'nuget.config') -Value $NuGetConfig -Encoding utf8

  $Program = @'
using System;
using System.Management.Automation;

using PowerShell ps = PowerShell.Create();
ps.AddScript("$PSVersionTable.PSVersion.ToString()");
foreach (PSObject result in ps.Invoke())
{
    Console.WriteLine(result);
}
'@
  Set-Content -Path (Join-Path $SampleDirectory 'Program.cs') -Value $Program -Encoding utf8

  [xml] $Project = Get-Content -LiteralPath $ProjectPath
  $PropertyGroup = @($Project.Project.PropertyGroup)[0]
  Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'RuntimeIdentifier' -Value $RuntimeIdentifier
  Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'PowerShellSDKIncludeAppHost' -Value 'true'
  $Project.Save($ProjectPath)

  Invoke-DotNet @('add', $ProjectPath, 'package', 'Microsoft.PowerShell.SDK', '--version', $PowerShellVersion, '--no-restore')
  Invoke-DotNet @('restore', $ProjectPath, '--configfile', (Join-Path $SampleDirectory 'nuget.config'), '--verbosity', 'minimal')

  $RestoredSdkPath = Join-Path $PackagesDirectory (Join-Path 'microsoft.powershell.sdk' $PowerShellVersion)
  foreach ($RelativePath in $ExpectedPackageEntries) {
    $RestoredPath = Join-Path $RestoredSdkPath ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path $RestoredPath -PathType Leaf)) {
      throw "Restored SDK package is missing expected file: $RestoredPath"
    }
  }

  Invoke-DotNet @('build', $ProjectPath, '--no-restore', '--nologo', '--verbosity', 'minimal')

  $OutputDirectory = Join-Path $SampleDirectory (Join-Path 'bin' (Join-Path 'Debug' (Join-Path $TargetFramework $RuntimeIdentifier)))
  $PwshPath = Join-Path $OutputDirectory $ExecutableName
  foreach ($FileName in @($ExecutableName, 'pwsh.dll', 'pwsh.runtimeconfig.json')) {
    $OutputPath = Join-Path $OutputDirectory $FileName
    if (-not (Test-Path $OutputPath -PathType Leaf)) {
      throw "Sample app output is missing expected apphost file: $OutputPath"
    }
  }

  $AppOutput = & dotnet run --project $ProjectPath --no-build
  if ($LASTEXITCODE -ne 0) {
    throw "Sample app failed with exit code $LASTEXITCODE"
  }
  $AppVersion = [string] ($AppOutput | Select-Object -Last 1)
  if ($AppVersion.Trim() -ne $PowerShellVersion) {
    throw "Sample app imported PowerShell SDK version '$AppVersion', expected '$PowerShellVersion'"
  }

  $PwshOutput = & $PwshPath -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
  if ($LASTEXITCODE -ne 0) {
    throw "$PwshPath failed with exit code $LASTEXITCODE"
  }
  $PwshVersion = [string] ($PwshOutput | Select-Object -Last 1)
  if ($PwshVersion.Trim() -ne $PowerShellVersion) {
    throw "$PwshPath reported PowerShell version '$PwshVersion', expected '$PowerShellVersion'"
  }

  Write-Host "Validated Microsoft.PowerShell.SDK $PowerShellVersion from $($Package.FullName)"
  Write-Host "Sample app imported PowerShell SDK $($AppVersion.Trim())"
  Write-Host "Sample output apphost reported PowerShell $($PwshVersion.Trim()): $PwshPath"
} finally {
  Set-Location $PreviousLocation
  $Env:NUGET_PACKAGES = $PreviousNuGetPackages
}
