[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $PackageDirectory,

  [Parameter(Mandatory)]
  [string] $PowerShellVersion,

  [Parameter(Mandatory)]
  [string] $TargetFramework,

  [string] $RuntimeIdentifier,

  [string] $PackageId = 'Devolutions.PowerShell.SDK',

  [string] $PackageVendorName = 'Devolutions'
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

function Add-RuntimeNativePublishDuplicateProbeTarget {
  param(
    [Parameter(Mandatory)]
    [xml] $Project,

    [Parameter(Mandatory)]
    [string] $PackageId,

    [Parameter(Mandatory)]
    [string] $PackageVersion,

    [Parameter(Mandatory)]
    [string[]] $RuntimeIdentifiers
  )

  $PackageDirectoryName = $PackageId.ToLowerInvariant()
  $Target = $Project.CreateElement('Target')
  $Target.SetAttribute('Name', 'InjectPowerShellSDKRuntimeNativePublishDuplicateProbe')
  $Target.SetAttribute('BeforeTargets', '_PowerShellSDKRemoveAutomaticRuntimeNativePublishItems')
  $ItemGroup = $Project.CreateElement('ItemGroup')
  foreach ($RuntimeIdentifier in $RuntimeIdentifiers) {
    $ExecutableName = if ($RuntimeIdentifier -like 'win-*') { 'pwsh.exe' } else { 'pwsh' }
    $PackageRelativePath = "runtimes/$RuntimeIdentifier/native/$ExecutableName"
    $PackagePath = "`$(NuGetPackageRoot)$PackageDirectoryName/$PackageVersion/$PackageRelativePath"
    $ResolvedFileToPublish = $Project.CreateElement('ResolvedFileToPublish')
    $ResolvedFileToPublish.SetAttribute('Include', $PackagePath)
    $ResolvedFileToPublish.SetAttribute('Condition', "Exists('$PackagePath')")

    foreach ($Metadata in @(
        @{ Name = 'RelativePath'; Value = $PackageRelativePath },
        @{ Name = 'CopyToPublishDirectory'; Value = 'PreserveNewest' },
        @{ Name = 'NuGetPackageId'; Value = $PackageId },
        @{ Name = 'PathInPackage'; Value = $PackageRelativePath })) {
      $MetadataElement = $Project.CreateElement($Metadata.Name)
      $MetadataElement.InnerText = $Metadata.Value
      [void] $ResolvedFileToPublish.AppendChild($MetadataElement)
    }

    [void] $ItemGroup.AppendChild($ResolvedFileToPublish)
  }

  [void] $Target.AppendChild($ItemGroup)
  [void] $Project.Project.AppendChild($Target)
}

function Add-PowerShellStandardPublishDuplicateProbeTarget {
  param(
    [Parameter(Mandatory)]
    [xml] $Project,

    [Parameter(Mandatory)]
    [string] $PackageId,

    [Parameter(Mandatory)]
    [string] $PackageVersion,

    [Parameter(Mandatory)]
    [string] $SdkPackageId,

    [Parameter(Mandatory)]
    [string] $SdkPackageVersion,

    [Parameter(Mandatory)]
    [string] $RuntimeAssetGroup,

    [Parameter(Mandatory)]
    [string] $TargetFramework
  )

  $PackageDirectoryName = $PackageId.ToLowerInvariant()
  $SdkPackageDirectoryName = $SdkPackageId.ToLowerInvariant()
  $Target = $Project.CreateElement('Target')
  $Target.SetAttribute('Name', 'InjectPowerShellStandardPublishDuplicateProbe')
  $Target.SetAttribute('BeforeTargets', '_PowerShellSDKRemoveAutomaticRuntimeNativePublishItems')

  $PropertyGroup = $Project.CreateElement('PropertyGroup')
  foreach ($Property in @(
      @{ Name = '_PowerShellStandardProbePath'; Value = "`$(NuGetPackageRoot)$PackageDirectoryName/$PackageVersion/lib/netstandard2.0/System.Management.Automation.dll" },
      @{ Name = '_PowerShellStandardProbeSourcePath'; Value = "`$(NuGetPackageRoot)$SdkPackageDirectoryName/$SdkPackageVersion/runtimes/$RuntimeAssetGroup/lib/$TargetFramework/System.Management.Automation.dll" })) {
    $Element = $Project.CreateElement($Property.Name)
    $Element.InnerText = $Property.Value
    [void] $PropertyGroup.AppendChild($Element)
  }
  [void] $Target.AppendChild($PropertyGroup)

  $MakeDir = $Project.CreateElement('MakeDir')
  $MakeDir.SetAttribute('Directories', "`$(NuGetPackageRoot)$PackageDirectoryName/$PackageVersion/lib/netstandard2.0")
  $MakeDir.SetAttribute('Condition', "Exists('`$(_PowerShellStandardProbeSourcePath)')")
  [void] $Target.AppendChild($MakeDir)

  $Copy = $Project.CreateElement('Copy')
  $Copy.SetAttribute('SourceFiles', '$(_PowerShellStandardProbeSourcePath)')
  $Copy.SetAttribute('DestinationFiles', '$(_PowerShellStandardProbePath)')
  $Copy.SetAttribute('Condition', "Exists('`$(_PowerShellStandardProbeSourcePath)')")
  [void] $Target.AppendChild($Copy)

  $ItemGroup = $Project.CreateElement('ItemGroup')
  $ResolvedFileToPublish = $Project.CreateElement('ResolvedFileToPublish')
  $ResolvedFileToPublish.SetAttribute('Include', '$(_PowerShellStandardProbePath)')
  $ResolvedFileToPublish.SetAttribute('Condition', "Exists('`$(_PowerShellStandardProbePath)')")
  foreach ($Metadata in @(
      @{ Name = 'RelativePath'; Value = 'System.Management.Automation.dll' },
      @{ Name = 'CopyToPublishDirectory'; Value = 'PreserveNewest' },
      @{ Name = 'NuGetPackageId'; Value = $PackageId },
      @{ Name = 'PathInPackage'; Value = 'lib/netstandard2.0/System.Management.Automation.dll' })) {
    $MetadataElement = $Project.CreateElement($Metadata.Name)
    $MetadataElement.InnerText = $Metadata.Value
    [void] $ResolvedFileToPublish.AppendChild($MetadataElement)
  }
  [void] $ItemGroup.AppendChild($ResolvedFileToPublish)
  [void] $Target.AppendChild($ItemGroup)

  [void] $Project.Project.AppendChild($Target)
}

function Assert-AppHostOutput {
  param(
    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string] $ExecutableName,

    [Parameter(Mandatory)]
    [string] $Description
  )

  foreach ($FileName in @($ExecutableName, 'pwsh.dll', 'pwsh.runtimeconfig.json', 'Microsoft.PowerShell.ConsoleHost.dll', 'System.Management.Automation.dll')) {
    $OutputPath = Join-Path $Directory $FileName
    if (-not (Test-Path $OutputPath -PathType Leaf)) {
      throw "$Description is missing expected apphost file: $OutputPath"
    }
  }

  foreach ($RelativeModulePath in @(
      'Modules/Microsoft.PowerShell.Management/Microsoft.PowerShell.Management.psd1',
      'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1',
      'Modules/Microsoft.PowerShell.Security/Microsoft.PowerShell.Security.psd1')) {
    $OutputPath = Join-Path $Directory ($RelativeModulePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path $OutputPath -PathType Leaf)) {
      throw "$Description is missing expected apphost module file: $OutputPath"
    }
  }
}

function Assert-RuntimeNativeAppHostOutput {
  param(
    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string] $RuntimeIdentifier,

    [Parameter(Mandatory)]
    [string] $ExecutableName,

    [Parameter(Mandatory)]
    [bool] $SelfContained,

    [Parameter(Mandatory)]
    [string] $Description
  )

  $NativeDirectory = Join-Path $Directory "runtimes/$RuntimeIdentifier/native"
  $ExecutablePath = Join-Path $NativeDirectory $ExecutableName
  if (-not (Test-Path $ExecutablePath -PathType Leaf)) {
    throw "$Description is missing expected runtime-native apphost file: $ExecutablePath"
  }

  $UnexpectedPayloadFiles = @(
    'pwsh.dll',
    'pwsh.runtimeconfig.json',
    'System.Management.Automation.dll',
    'Microsoft.PowerShell.ConsoleHost.dll',
    'Microsoft.Management.Infrastructure.dll',
    'Newtonsoft.Json.dll',
    'Modules/Microsoft.PowerShell.Management/Microsoft.PowerShell.Management.psd1'
  )
  foreach ($RelativePayloadPath in $UnexpectedPayloadFiles) {
    $PayloadPath = Join-Path $NativeDirectory ($RelativePayloadPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (Test-Path $PayloadPath) {
      throw "$Description unexpectedly duplicated shared PowerShell payload under runtime-native apphost directory: $PayloadPath"
    }
  }

  return $ExecutablePath
}

function Assert-NoRootRuntimeNativeAppHostOutput {
  param(
    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string] $ExecutableName,

    [Parameter(Mandatory)]
    [string] $Description
  )

  $RootExecutablePath = Join-Path $Directory $ExecutableName
  if (Test-Path $RootExecutablePath -PathType Leaf) {
    throw "$Description unexpectedly copied the runtime-native apphost to the app root: $RootExecutablePath"
  }
}

function Assert-SharedPowerShellOutput {
  param(
    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [bool] $SelfContained,

    [Parameter(Mandatory)]
    [string] $Description
  )

  foreach ($FileName in @('pwsh.dll', 'pwsh.runtimeconfig.json', 'Microsoft.PowerShell.ConsoleHost.dll', 'System.Management.Automation.dll')) {
    $OutputPath = Join-Path $Directory $FileName
    if (-not (Test-Path $OutputPath -PathType Leaf)) {
      throw "$Description is missing expected shared PowerShell payload file: $OutputPath"
    }
  }

  foreach ($RelativeModulePath in @(
      'Modules/Microsoft.PowerShell.Management/Microsoft.PowerShell.Management.psd1',
      'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1',
      'Modules/Microsoft.PowerShell.Security/Microsoft.PowerShell.Security.psd1')) {
    $OutputPath = Join-Path $Directory ($RelativeModulePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path $OutputPath -PathType Leaf)) {
      throw "$Description is missing expected shared PowerShell module file: $OutputPath"
    }
  }

  Assert-RuntimeConfigMode -RuntimeConfigPath (Join-Path $Directory 'pwsh.runtimeconfig.json') -SelfContained $SelfContained -Description $Description
}

function Assert-NoSharedPowerShellRuntimeLibDuplicate {
  param(
    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string] $RuntimeAssetGroup,

    [Parameter(Mandatory)]
    [string] $TargetFramework,

    [Parameter(Mandatory)]
    [string] $Description
  )

  foreach ($RelativePayloadPath in @(
      "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/System.Management.Automation.dll",
      "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/Microsoft.PowerShell.SDK.dll",
      "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/Modules/Microsoft.PowerShell.Management/Microsoft.PowerShell.Management.psd1")) {
    $PayloadPath = Join-Path $Directory ($RelativePayloadPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (Test-Path $PayloadPath) {
      throw "$Description unexpectedly duplicated shared PowerShell payload under runtime lib asset directory: $PayloadPath"
    }
  }
}

function Assert-FileContentMatches {
  param(
    [Parameter(Mandatory)]
    [string] $ExpectedPath,

    [Parameter(Mandatory)]
    [string] $ActualPath,

    [Parameter(Mandatory)]
    [string] $Description
  )

  if (-not (Test-Path $ExpectedPath -PathType Leaf)) {
    throw "$Description expected file does not exist: $ExpectedPath"
  }
  if (-not (Test-Path $ActualPath -PathType Leaf)) {
    throw "$Description actual file does not exist: $ActualPath"
  }

  $ExpectedHash = (Get-FileHash -LiteralPath $ExpectedPath -Algorithm SHA256).Hash
  $ActualHash = (Get-FileHash -LiteralPath $ActualPath -Algorithm SHA256).Hash
  if ($ActualHash -ne $ExpectedHash) {
    throw "$Description file content mismatch. Expected '$ExpectedPath' ($ExpectedHash), got '$ActualPath' ($ActualHash)."
  }
}

function Assert-SharedPackagePayloadPreserved {
  param(
    [Parameter(Mandatory)]
    [string] $RestoredSdkPath,

    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string] $RuntimeAssetGroup,

    [Parameter(Mandatory)]
    [string] $Description
  )

  foreach ($FileName in @('System.Management.Automation.dll', 'Microsoft.PowerShell.ConsoleHost.dll')) {
    $ExpectedPath = Join-Path $RestoredSdkPath "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/$FileName"
    $ActualPath = Join-Path $Directory $FileName
    Assert-FileContentMatches -ExpectedPath $ExpectedPath -ActualPath $ActualPath -Description "$Description shared $FileName"
  }
}

function Invoke-RuntimeNativeOverwriteProbe {
  param(
    [Parameter(Mandatory)]
    [string] $ProjectPath,

    [Parameter(Mandatory)]
    [string] $Directory,

    [Parameter(Mandatory)]
    [string] $RestoredSdkPath,

    [Parameter(Mandatory)]
    [string[]] $RuntimeIdentifiers,

    [Parameter(Mandatory)]
    [string] $CurrentRuntimeIdentifier,

    [Parameter(Mandatory)]
    [string] $TargetName,

    [string] $PublishDirectory,

    [Parameter(Mandatory)]
    [string] $Description
  )

  $RootPayloadPath = Join-Path $Directory 'System.Management.Automation.dll'
  $CollisionPayloadPath = Join-Path $Directory (Split-Path $ProjectPath -LeafBase)
  $CollisionPayloadPath = [System.IO.Path]::ChangeExtension($CollisionPayloadPath, '.dll')
  if (-not (Test-Path $RootPayloadPath -PathType Leaf) -or -not (Test-Path $CollisionPayloadPath -PathType Leaf)) {
    return
  }

  $BackupPath = "$RootPayloadPath.sdkvalidation.bak"
  Copy-Item -LiteralPath $RootPayloadPath -Destination $BackupPath -Force
  try {
    Copy-Item -LiteralPath $CollisionPayloadPath -Destination $RootPayloadPath -Force

    $RuntimeIdentifiersPropertyValue = $RuntimeIdentifiers -join '%3B'
    $Arguments = @(
      'msbuild',
      $ProjectPath,
      '-nologo',
      '-verbosity:minimal',
      "-t:$TargetName",
      "/p:RuntimeIdentifier=$CurrentRuntimeIdentifier",
      "/p:PowerShellSDKIncludeRuntimeNativeAppHosts=true",
      "/p:PowerShellSDKRuntimeNativeAppHostRuntimeIdentifiers=$RuntimeIdentifiersPropertyValue"
    )
    if ($PublishDirectory) {
      $PublishDirectoryProperty = $PublishDirectory
      if (-not $PublishDirectoryProperty.EndsWith([System.IO.Path]::DirectorySeparatorChar) -and
          -not $PublishDirectoryProperty.EndsWith([System.IO.Path]::AltDirectorySeparatorChar)) {
        $PublishDirectoryProperty = "$PublishDirectoryProperty$([System.IO.Path]::DirectorySeparatorChar)"
      }
      $Arguments += "/p:PublishDir=$PublishDirectoryProperty"
    }

    Invoke-DotNet $Arguments

    $RuntimeAssetGroup = if ($CurrentRuntimeIdentifier -like 'win-*') { 'win' } else { 'unix' }
    Assert-SharedPackagePayloadPreserved -RestoredSdkPath $RestoredSdkPath -Directory $Directory -RuntimeAssetGroup $RuntimeAssetGroup -Description $Description
  } finally {
    Copy-Item -LiteralPath $BackupPath -Destination $RootPayloadPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $BackupPath -Force -ErrorAction SilentlyContinue
  }
}

function Assert-RuntimeConfigMode {
  param(
    [Parameter(Mandatory)]
    [string] $RuntimeConfigPath,

    [Parameter(Mandatory)]
    [bool] $SelfContained,

    [Parameter(Mandatory)]
    [string] $Description
  )

  $RuntimeConfig = Get-Content -LiteralPath $RuntimeConfigPath -Raw
  if ($SelfContained) {
    if ($RuntimeConfig -notmatch '"includedFrameworks"\s*:') {
      throw "$Description runtimeconfig is not self-contained; missing includedFrameworks: $RuntimeConfigPath"
    }
    if ($RuntimeConfig -match '"frameworks?"\s*:') {
      throw "$Description runtimeconfig still contains framework-dependent entries: $RuntimeConfigPath"
    }
    return
  }

  if ($RuntimeConfig -match '"includedFrameworks"\s*:') {
    throw "$Description runtimeconfig was unexpectedly rewritten as self-contained: $RuntimeConfigPath"
  }
  if ($RuntimeConfig -notmatch '"frameworks?"\s*:') {
    throw "$Description runtimeconfig does not contain framework-dependent entries: $RuntimeConfigPath"
  }
}

function Invoke-PwshVersionCheck {
  param(
    [Parameter(Mandatory)]
    [string] $PwshPath,

    [Parameter(Mandatory)]
    [string] $ExpectedVersion
  )

  $PwshOutput = & $PwshPath -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
  if ($LASTEXITCODE -ne 0) {
    throw "$PwshPath failed with exit code $LASTEXITCODE"
  }
  $PwshVersion = [string] ($PwshOutput | Select-Object -Last 1)
  if ($PwshVersion.Trim() -ne $ExpectedVersion) {
    throw "$PwshPath reported PowerShell version '$PwshVersion', expected '$ExpectedVersion'"
  }

  return $PwshVersion.Trim()
}

function Invoke-PwshModuleProbe {
  param(
    [Parameter(Mandatory)]
    [string] $PwshPath,

    [Parameter(Mandatory)]
    [string] $ModuleRoot
  )

  $PreviousPSModulePath = $Env:PSModulePath
  $PreviousExpectedModuleRoot = $Env:PowerShellSDKExpectedModuleRoot
  try {
    $Env:PSModulePath = ''
    $Env:PowerShellSDKExpectedModuleRoot = $ModuleRoot
    $ModuleProbe = @'
$ErrorActionPreference = 'Stop'
$expectedModuleRoot = $env:PowerShellSDKExpectedModuleRoot
foreach ($moduleName in 'Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Utility') {
  $module = $null
  foreach ($candidate in Get-Module -ListAvailable $moduleName) {
    $module = $candidate
    break
  }
  if ($null -eq $module) {
    throw "Module '$moduleName' is not available"
  }

  if (-not $module.Path.StartsWith($expectedModuleRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Module '$moduleName' was loaded from '$($module.Path)' instead of '$expectedModuleRoot'"
  }
}

$getProcess = Get-Command Get-Process -ErrorAction Stop
if ($getProcess.Source -ne 'Microsoft.PowerShell.Management') {
  throw "Get-Process resolved from '$($getProcess.Source)' instead of Microsoft.PowerShell.Management"
}

$selectObject = Get-Command Select-Object -ErrorAction Stop
if ($selectObject.Source -ne 'Microsoft.PowerShell.Utility') {
  throw "Select-Object resolved from '$($selectObject.Source)' instead of Microsoft.PowerShell.Utility"
}
'@
    $PwshModuleProbeOutput = & $PwshPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $ModuleProbe
    if ($LASTEXITCODE -ne 0) {
      throw "$PwshPath failed module probe with exit code $LASTEXITCODE"
    }
  } finally {
    $Env:PSModulePath = $PreviousPSModulePath
    $Env:PowerShellSDKExpectedModuleRoot = $PreviousExpectedModuleRoot
  }
}

function Read-ZipEntryText {
  param(
    [Parameter(Mandatory)]
    [System.IO.Compression.ZipArchiveEntry] $Entry
  )

  $Stream = $Entry.Open()
  $Reader = [System.IO.StreamReader]::new($Stream)
  try {
    return $Reader.ReadToEnd()
  } finally {
    $Reader.Dispose()
    $Stream.Dispose()
  }
}

function Get-NuspecMetadataValue {
  param(
    [Parameter(Mandatory)]
    [xml] $Nuspec,

    [Parameter(Mandatory)]
    [System.Xml.XmlNamespaceManager] $NamespaceManager,

    [Parameter(Mandatory)]
    [string] $Name
  )

  $Element = $Nuspec.SelectSingleNode("/n:package/n:metadata/n:$Name", $NamespaceManager)
  if (-not $Element) {
    throw "SDK package nuspec is missing required metadata element '$Name'"
  }

  return $Element.InnerText
}

if (-not $RuntimeIdentifier) {
  $RuntimeIdentifier = Get-DefaultRuntimeIdentifier
}

$PackageDirectoryPath = (Resolve-Path -LiteralPath $PackageDirectory).Path
$Package = Get-ChildItem -LiteralPath $PackageDirectoryPath -Filter "$PackageId.$PowerShellVersion*.nupkg" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
if (-not $Package) {
  throw "Unable to find $PackageId.$PowerShellVersion nupkg in $PackageDirectoryPath"
}

$EmbeddedPowerShellPackageIds = @(
  'Microsoft.PowerShell.SDK',
  'System.Management.Automation',
  'Microsoft.PowerShell.Commands.Management',
  'Microsoft.PowerShell.Commands.Utility',
  'Microsoft.PowerShell.ConsoleHost',
  'Microsoft.PowerShell.Security',
  'Microsoft.PowerShell.Commands.Diagnostics',
  'Microsoft.Management.Infrastructure.CimCmdlets',
  'Microsoft.WSMan.Management',
  'Microsoft.PowerShell.CoreCLR.Eventing',
  'Microsoft.WSMan.Runtime'
)

$ExecutableName = if ($RuntimeIdentifier -like 'win-*') { 'pwsh.exe' } else { 'pwsh' }
$RuntimeAssetGroup = if ($RuntimeIdentifier -like 'win-*') { 'win' } else { 'unix' }
$RuntimeNativeValidationRids = if ($RuntimeAssetGroup -eq 'win') { @('win-x64', 'win-arm64') } else { @($RuntimeIdentifier) }
$SampleTargetFramework = if ($RuntimeAssetGroup -eq 'win') { "$TargetFramework-windows10.0.19041" } else { $TargetFramework }
$PowerShellStandardPackageId = 'PowerShellStandard.Library'
$PowerShellStandardPackageVersion = '5.1.0'
$ExpectedPackageEntries = @(
  "buildTransitive/$PackageId.targets",
  "tools/apphost/$RuntimeIdentifier/$ExecutableName",
  "tools/apphost/$RuntimeIdentifier/pwsh.dll",
  "tools/apphost/$RuntimeIdentifier/pwsh.runtimeconfig.json",
  "ref/$TargetFramework/System.Management.Automation.dll",
  "ref/$TargetFramework/Microsoft.PowerShell.Commands.Management.dll",
  "ref/$TargetFramework/Microsoft.PowerShell.Commands.Utility.dll",
  "ref/$TargetFramework/Microsoft.PowerShell.ConsoleHost.dll",
  "ref/$TargetFramework/Microsoft.PowerShell.Security.dll",
  "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/Microsoft.PowerShell.SDK.dll",
  "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/System.Management.Automation.dll",
  "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/Microsoft.PowerShell.Commands.Management.dll",
  "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/Microsoft.PowerShell.Commands.Utility.dll",
  "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/Microsoft.PowerShell.ConsoleHost.dll",
  "runtimes/$RuntimeAssetGroup/lib/$TargetFramework/Microsoft.PowerShell.Security.dll"
)
foreach ($RuntimeNativeRid in $RuntimeNativeValidationRids) {
  $RuntimeNativeExecutableName = if ($RuntimeNativeRid -like 'win-*') { 'pwsh.exe' } else { 'pwsh' }
  $ExpectedPackageEntries += @(
    "tools/apphost/$RuntimeNativeRid/$RuntimeNativeExecutableName",
    "tools/apphost/$RuntimeNativeRid/pwsh.dll",
    "tools/apphost/$RuntimeNativeRid/pwsh.runtimeconfig.json",
    "runtimes/$RuntimeNativeRid/native/$RuntimeNativeExecutableName"
  )
}
if ($RuntimeAssetGroup -eq 'win') {
  $ExpectedPackageEntries += @(
    "ref/$TargetFramework/Microsoft.PowerShell.Commands.Diagnostics.dll",
    "ref/$TargetFramework/Microsoft.Management.Infrastructure.CimCmdlets.dll",
    "ref/$TargetFramework/Microsoft.WSMan.Management.dll",
    "ref/$TargetFramework/Microsoft.PowerShell.CoreCLR.Eventing.dll",
    "ref/$TargetFramework/Microsoft.WSMan.Runtime.dll",
    "runtimes/win/lib/$TargetFramework/Microsoft.PowerShell.Commands.Diagnostics.dll",
    "runtimes/win/lib/$TargetFramework/Microsoft.Management.Infrastructure.CimCmdlets.dll",
    "runtimes/win/lib/$TargetFramework/Microsoft.WSMan.Management.dll",
    "runtimes/win/lib/$TargetFramework/Microsoft.PowerShell.CoreCLR.Eventing.dll",
    "runtimes/win/lib/$TargetFramework/Microsoft.WSMan.Runtime.dll"
  )
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$Zip = [System.IO.Compression.ZipFile]::OpenRead($Package.FullName)
try {
  foreach ($EntryName in $ExpectedPackageEntries) {
    if (-not ($Zip.Entries | Where-Object FullName -EQ $EntryName)) {
      throw "SDK package is missing expected entry: $EntryName"
    }
  }

  if ($PackageVendorName) {
    $NuspecEntry = $Zip.Entries |
      Where-Object { $_.FullName -like '*.nuspec' -and $_.FullName -notlike '*/*' } |
      Select-Object -First 1
    if (-not $NuspecEntry) {
      throw "SDK package is missing a root nuspec"
    }

    [xml] $Nuspec = Read-ZipEntryText -Entry $NuspecEntry
    $NamespaceManager = [System.Xml.XmlNamespaceManager]::new($Nuspec.NameTable)
    $NamespaceManager.AddNamespace('n', $Nuspec.DocumentElement.NamespaceURI)

    $NuspecPackageId = Get-NuspecMetadataValue -Nuspec $Nuspec -NamespaceManager $NamespaceManager -Name 'id'
    if ($NuspecPackageId -ne $PackageId) {
      throw "SDK package nuspec id is '$NuspecPackageId', expected '$PackageId'"
    }

    foreach ($ElementName in @('authors', 'owners', 'copyright')) {
      $Value = Get-NuspecMetadataValue -Nuspec $Nuspec -NamespaceManager $NamespaceManager -Name $ElementName
      if ($Value -notlike "*$PackageVendorName*") {
        throw "SDK package nuspec metadata '$ElementName' does not contain '$PackageVendorName': $Value"
      }
      if ($PackageVendorName -ne 'Microsoft' -and $Value -like '*Microsoft*') {
        throw "SDK package nuspec metadata '$ElementName' still contains 'Microsoft': $Value"
      }
    }

    $OriginalDependencies = @(
      $Nuspec.SelectNodes('/n:package/n:metadata/n:dependencies//n:dependency', $NamespaceManager) |
        Where-Object { $EmbeddedPowerShellPackageIds -contains [string] $_.id } |
        ForEach-Object { [string] $_.id }
    )
    if ($OriginalDependencies) {
      throw "SDK package nuspec still references original PowerShell package dependencies: $($OriginalDependencies -join ', ')"
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
      <package pattern="$PackageId" />
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
  $TargetFrameworkElement = $PropertyGroup.SelectSingleNode('TargetFramework')
  if ($TargetFrameworkElement) {
    $TargetFrameworkElement.InnerText = $SampleTargetFramework
  } else {
    Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'TargetFramework' -Value $SampleTargetFramework
  }
  Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'RuntimeIdentifier' -Value $RuntimeIdentifier
  Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'PowerShellSDKIncludeRuntimeNativeAppHosts' -Value 'true'
  Add-ProjectProperty -Project $Project -PropertyGroup $PropertyGroup -Name 'PowerShellSDKRuntimeNativeAppHostRuntimeIdentifiers' -Value ($RuntimeNativeValidationRids -join ';')
  Add-RuntimeNativePublishDuplicateProbeTarget -Project $Project -PackageId $PackageId -PackageVersion $PowerShellVersion -RuntimeIdentifiers $RuntimeNativeValidationRids
  if ($RuntimeAssetGroup -eq 'win') {
    Add-PowerShellStandardPublishDuplicateProbeTarget -Project $Project -PackageId $PowerShellStandardPackageId -PackageVersion $PowerShellStandardPackageVersion -SdkPackageId $PackageId -SdkPackageVersion $PowerShellVersion -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework
  }
  $Project.Save($ProjectPath)

  Invoke-DotNet @('add', $ProjectPath, 'package', $PackageId, '--version', $PowerShellVersion, '--no-restore')
  Invoke-DotNet @('restore', $ProjectPath, '--configfile', (Join-Path $SampleDirectory 'nuget.config'), '--verbosity', 'minimal')

  $AssetsPath = Join-Path (Split-Path $ProjectPath -Parent) 'obj/project.assets.json'
  $Assets = Get-Content -LiteralPath $AssetsPath -Raw | ConvertFrom-Json
  $RestoredPackageIds = @(
    $Assets.libraries.PSObject.Properties.Name |
      ForEach-Object { ($_ -split '/', 2)[0] }
  )
  $RestoredOriginalPowerShellPackageIds = @(
    $RestoredPackageIds |
      Where-Object { $EmbeddedPowerShellPackageIds -contains $_ }
  )
  if ($RestoredOriginalPowerShellPackageIds) {
    throw "Restore imported original PowerShell package IDs instead of vendored IDs: $($RestoredOriginalPowerShellPackageIds -join ', ')"
  }

  $RestoredSdkPackageDirectoryName = $PackageId.ToLowerInvariant()
  $RestoredSdkPath = Join-Path $PackagesDirectory (Join-Path $RestoredSdkPackageDirectoryName $PowerShellVersion)
  foreach ($RelativePath in $ExpectedPackageEntries) {
    $RestoredPath = Join-Path $RestoredSdkPath ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path $RestoredPath -PathType Leaf)) {
      throw "Restored SDK package is missing expected file: $RestoredPath"
    }
  }

  Invoke-DotNet @('build', $ProjectPath, '--no-restore', '--nologo', '--verbosity', 'minimal')

  $OutputDirectory = Join-Path $SampleDirectory (Join-Path 'bin' (Join-Path 'Debug' (Join-Path $SampleTargetFramework $RuntimeIdentifier)))
  Assert-SharedPowerShellOutput -Directory $OutputDirectory -SelfContained $false -Description 'Sample app output'
  Assert-NoRootRuntimeNativeAppHostOutput -Directory $OutputDirectory -ExecutableName $ExecutableName -Description 'Sample app output'
  Assert-NoSharedPowerShellRuntimeLibDuplicate -Directory $OutputDirectory -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework -Description 'Sample app output'
  Assert-SharedPackagePayloadPreserved -RestoredSdkPath $RestoredSdkPath -Directory $OutputDirectory -RuntimeAssetGroup $RuntimeAssetGroup -Description 'Sample app output'
  foreach ($RuntimeNativeRid in $RuntimeNativeValidationRids) {
    $RuntimeNativeExecutableName = if ($RuntimeNativeRid -like 'win-*') { 'pwsh.exe' } else { 'pwsh' }
    $RuntimeNativePwshPath = Assert-RuntimeNativeAppHostOutput -Directory $OutputDirectory -RuntimeIdentifier $RuntimeNativeRid -ExecutableName $RuntimeNativeExecutableName -SelfContained $false -Description "Sample app output [$RuntimeNativeRid]"
    if ($RuntimeNativeRid -eq $RuntimeIdentifier) {
      [void] (Invoke-PwshVersionCheck -PwshPath $RuntimeNativePwshPath -ExpectedVersion $PowerShellVersion)
      Invoke-PwshModuleProbe -PwshPath $RuntimeNativePwshPath -ModuleRoot (Join-Path $OutputDirectory 'Modules')
    }
  }
  Invoke-RuntimeNativeOverwriteProbe -ProjectPath $ProjectPath -Directory $OutputDirectory -RestoredSdkPath $RestoredSdkPath -RuntimeIdentifiers $RuntimeNativeValidationRids -CurrentRuntimeIdentifier $RuntimeIdentifier -TargetName 'PowerShellSDKCopyRuntimeNativeAppHostsToOutput' -Description 'Sample app output overwrite probe'

  $AppOutput = & dotnet run --project $ProjectPath --no-build
  if ($LASTEXITCODE -ne 0) {
    throw "Sample app failed with exit code $LASTEXITCODE"
  }
  $AppVersion = [string] ($AppOutput | Select-Object -Last 1)
  if ($AppVersion.Trim() -ne $PowerShellVersion) {
    throw "Sample app imported PowerShell SDK version '$AppVersion', expected '$PowerShellVersion'"
  }

  Invoke-DotNet @('publish', $ProjectPath, '--nologo', '--verbosity', 'minimal', '-c', 'Release', '-r', $RuntimeIdentifier, '--self-contained', 'true')

  $PublishDirectory = Join-Path $SampleDirectory (Join-Path 'bin' (Join-Path 'Release' (Join-Path $SampleTargetFramework (Join-Path $RuntimeIdentifier 'publish'))))
  Assert-SharedPowerShellOutput -Directory $PublishDirectory -SelfContained $true -Description 'Sample self-contained publish output'
  Assert-NoRootRuntimeNativeAppHostOutput -Directory $PublishDirectory -ExecutableName $ExecutableName -Description 'Sample self-contained publish output'
  Assert-NoSharedPowerShellRuntimeLibDuplicate -Directory $PublishDirectory -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework -Description 'Sample self-contained publish output'
  Assert-SharedPackagePayloadPreserved -RestoredSdkPath $RestoredSdkPath -Directory $PublishDirectory -RuntimeAssetGroup $RuntimeAssetGroup -Description 'Sample self-contained publish output'
  foreach ($RuntimeNativeRid in $RuntimeNativeValidationRids) {
    $RuntimeNativeExecutableName = if ($RuntimeNativeRid -like 'win-*') { 'pwsh.exe' } else { 'pwsh' }
    $RuntimeNativePwshPath = Assert-RuntimeNativeAppHostOutput -Directory $PublishDirectory -RuntimeIdentifier $RuntimeNativeRid -ExecutableName $RuntimeNativeExecutableName -SelfContained $true -Description "Sample self-contained publish output [$RuntimeNativeRid]"
    if ($RuntimeNativeRid -eq $RuntimeIdentifier) {
      $PwshVersion = Invoke-PwshVersionCheck -PwshPath $RuntimeNativePwshPath -ExpectedVersion $PowerShellVersion
      Invoke-PwshModuleProbe -PwshPath $RuntimeNativePwshPath -ModuleRoot (Join-Path $PublishDirectory 'Modules')
    }
  }

  $FrameworkDependentPublishDirectory = Join-Path $SampleDirectory (Join-Path 'bin' (Join-Path 'Release' (Join-Path $SampleTargetFramework (Join-Path $RuntimeIdentifier 'publish-framework-dependent'))))
  Remove-Item $FrameworkDependentPublishDirectory -Recurse -Force -ErrorAction SilentlyContinue
  Invoke-DotNet @('publish', $ProjectPath, '--nologo', '--verbosity', 'minimal', '-c', 'Release', '-r', $RuntimeIdentifier, '--self-contained', 'false', '-o', $FrameworkDependentPublishDirectory)
  Assert-SharedPowerShellOutput -Directory $FrameworkDependentPublishDirectory -SelfContained $false -Description 'Sample framework-dependent publish output'
  Assert-NoRootRuntimeNativeAppHostOutput -Directory $FrameworkDependentPublishDirectory -ExecutableName $ExecutableName -Description 'Sample framework-dependent publish output'
  Assert-NoSharedPowerShellRuntimeLibDuplicate -Directory $FrameworkDependentPublishDirectory -RuntimeAssetGroup $RuntimeAssetGroup -TargetFramework $TargetFramework -Description 'Sample framework-dependent publish output'
  Assert-SharedPackagePayloadPreserved -RestoredSdkPath $RestoredSdkPath -Directory $FrameworkDependentPublishDirectory -RuntimeAssetGroup $RuntimeAssetGroup -Description 'Sample framework-dependent publish output'
  foreach ($RuntimeNativeRid in $RuntimeNativeValidationRids) {
    $RuntimeNativeExecutableName = if ($RuntimeNativeRid -like 'win-*') { 'pwsh.exe' } else { 'pwsh' }
    $RuntimeNativePwshPath = Assert-RuntimeNativeAppHostOutput -Directory $FrameworkDependentPublishDirectory -RuntimeIdentifier $RuntimeNativeRid -ExecutableName $RuntimeNativeExecutableName -SelfContained $false -Description "Sample framework-dependent publish output [$RuntimeNativeRid]"
    if ($RuntimeNativeRid -eq $RuntimeIdentifier) {
      [void] (Invoke-PwshVersionCheck -PwshPath $RuntimeNativePwshPath -ExpectedVersion $PowerShellVersion)
    }
  }

  Write-Host "Validated $PackageId $PowerShellVersion from $($Package.FullName)"
  Write-Host "Sample app imported vendored PowerShell SDK $($AppVersion.Trim())"
  Write-Host "Sample self-contained publish runtime-native apphost reported PowerShell $PwshVersion"
  Write-Host "Sample framework-dependent publish runtime-native apphost reported PowerShell $PowerShellVersion"
} finally {
  Set-Location $PreviousLocation
  $Env:NUGET_PACKAGES = $PreviousNuGetPackages
}
