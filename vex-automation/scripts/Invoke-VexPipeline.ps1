param(
  [string] $SbomPath = ".\sbom.cdx.json",

  [string] $DecisionPath = ".\vex-automation\decisions.example.json",

  [string] $OutputDir = ".\vex-automation\out",

  [string] $TrivyImage = "aquasec/trivy:latest",

  [string] $ProductId,

  [switch] $SkipScanWithVex
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

function Get-RelativeDockerPath([string] $RootPath, [string] $Path) {
  $rootFullPath = [System.IO.Path]::GetFullPath($RootPath)
  $targetFullPath = [System.IO.Path]::GetFullPath($Path)
  if (-not $rootFullPath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $rootFullPath = $rootFullPath + [System.IO.Path]::DirectorySeparatorChar
  }
  $rootUri = New-Object System.Uri($rootFullPath)
  $targetUri = New-Object System.Uri($targetFullPath)
  $relativePath = [System.Uri]::UnescapeDataString($rootUri.MakeRelativeUri($targetUri).ToString())
  return ($relativePath -replace "\\", "/")
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$resolvedSbomPath = (Resolve-Path -LiteralPath $SbomPath).Path
$resolvedDecisionPath = (Resolve-Path -LiteralPath $DecisionPath).Path
$resolvedOutputDir = (New-Item -ItemType Directory -Force -Path $OutputDir).FullName

$scanPath = Join-Path $resolvedOutputDir "trivy-sbom-scan.json"
$vexPath = Join-Path $resolvedOutputDir "petclinic.openvex.json"
$scanWithVexPath = Join-Path $resolvedOutputDir "trivy-sbom-scan-with-vex.json"

$sbomDockerPath = "/work/$(Get-RelativeDockerPath $repoRoot $resolvedSbomPath)"
$scanDockerPath = "/work/$(Get-RelativeDockerPath $repoRoot $scanPath)"
$vexDockerPath = "/work/$(Get-RelativeDockerPath $repoRoot $vexPath)"
$scanWithVexDockerPath = "/work/$(Get-RelativeDockerPath $repoRoot $scanWithVexPath)"

Write-Host "Scanning SBOM with Trivy..."
docker run --rm `
  -v "${repoRoot}:/work" `
  $TrivyImage sbom `
  --quiet `
  --format json `
  --output $scanDockerPath `
  $sbomDockerPath

if ($LASTEXITCODE -ne 0) {
  throw "Trivy SBOM scan failed with exit code $LASTEXITCODE."
}

Write-Host "Generating OpenVEX..."
$generator = Join-Path $PSScriptRoot "Invoke-OpenVexFromTrivy.ps1"
$generatorArgs = @{
  TrivyJsonPath = $scanPath
  SbomPath = $resolvedSbomPath
  DecisionPath = $resolvedDecisionPath
  OutputPath = $vexPath
}
if (-not [string]::IsNullOrWhiteSpace($ProductId)) {
  $generatorArgs.ProductId = $ProductId
}

& $generator @generatorArgs | Format-List

if (-not $SkipScanWithVex) {
  Write-Host "Re-scanning SBOM with generated VEX..."
  docker run --rm `
    -v "${repoRoot}:/work" `
    $TrivyImage sbom `
    --quiet `
    --format json `
    --vex $vexDockerPath `
    --output $scanWithVexDockerPath `
    $sbomDockerPath

  if ($LASTEXITCODE -ne 0) {
    throw "Trivy scan with VEX failed with exit code $LASTEXITCODE."
  }
}

[pscustomobject]@{
  Sbom = $resolvedSbomPath
  TrivyScan = $scanPath
  OpenVex = $vexPath
  TrivyScanWithVex = if ($SkipScanWithVex) { $null } else { $scanWithVexPath }
}
