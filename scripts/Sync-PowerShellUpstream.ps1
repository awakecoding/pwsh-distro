[CmdletBinding(SupportsShouldProcess)]
param(
  [string] $UpstreamRepository = 'https://github.com/PowerShell/PowerShell.git',

  [string] $UpstreamBranch = 'master',

  [string] $UpstreamRemote = 'powershell',

  [string] $OriginRemote = 'origin',

  [switch] $SyncTags,

  [switch] $Push
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Invoke-Git {
  param(
    [Parameter(Mandatory, ValueFromRemainingArguments)]
    [string[]] $Arguments
  )

  & git @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

function Test-GitRemote {
  param(
    [Parameter(Mandatory)]
    [string] $Name
  )

  & git remote get-url $Name *> $null
  return $LASTEXITCODE -eq 0
}

if (Test-GitRemote $UpstreamRemote) {
  Invoke-Git remote set-url $UpstreamRemote $UpstreamRepository
} else {
  Invoke-Git remote add $UpstreamRemote $UpstreamRepository
}

Invoke-Git fetch $UpstreamRemote --prune --no-tags

$RemoteBranchRef = "refs/remotes/$UpstreamRemote/$UpstreamBranch"
Invoke-Git rev-parse --verify $RemoteBranchRef
$UpstreamCommit = (& git rev-parse $RemoteBranchRef).Trim()
if ($LASTEXITCODE -ne 0) {
  throw "Unable to resolve $RemoteBranchRef"
}

if ($PSCmdlet.ShouldProcess('refs/heads/upstream', "Update to $UpstreamCommit")) {
  Invoke-Git update-ref refs/heads/upstream $UpstreamCommit
}

if ($Push) {
  if ($PSCmdlet.ShouldProcess($OriginRemote, 'Push refs/heads/upstream')) {
    Invoke-Git push $OriginRemote refs/heads/upstream:refs/heads/upstream --force
  }
}

if ($SyncTags) {
  Invoke-Git fetch $UpstreamRemote --prune --no-tags '+refs/tags/*:refs/tags/upstream/*'
  $Tags = @(git for-each-ref --format='%(refname)' refs/tags/upstream)
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to enumerate refs/tags/upstream"
  }

  if ($Tags.Count -eq 0) {
    Write-Host 'No upstream tags found.'
    return
  }

  Write-Host "Synchronized $($Tags.Count) upstream tag(s) locally under refs/tags/upstream/*."

  if ($Push) {
    foreach ($Tag in $Tags) {
      if ($PSCmdlet.ShouldProcess($OriginRemote, "Push $Tag")) {
        Invoke-Git push $OriginRemote "$Tag`:$Tag"
      }
    }
  }
}
