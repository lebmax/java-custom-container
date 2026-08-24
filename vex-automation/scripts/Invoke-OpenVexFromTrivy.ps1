param(
  [Parameter(Mandatory = $true)]
  [string] $TrivyJsonPath,

  [Parameter(Mandatory = $true)]
  [string] $SbomPath,

  [Parameter(Mandatory = $true)]
  [string] $DecisionPath,

  [Parameter(Mandatory = $true)]
  [string] $OutputPath,

  [string] $ProductId,

  [string] $Author = "Unknown Author",

  [string] $Role = "Document Creator"
)

$ErrorActionPreference = "Stop"

function Convert-ToArray($Value) {
  if ($null -eq $Value) {
    return @()
  }
  if ($Value -is [array]) {
    return $Value
  }
  return @($Value)
}

function Get-PropertyValue($Object, [string] $Name) {
  if ($null -eq $Object) {
    return $null
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
  }
  return $property.Value
}

function Normalize-KeyPart([string] $Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return "*"
  }
  return $Value.Trim()
}

function Get-Decision($DecisionMap, [string] $VulnerabilityId, [string] $Purl) {
  $vulnerability = Normalize-KeyPart $VulnerabilityId
  $component = Normalize-KeyPart $Purl
  $keys = @(
    "$vulnerability|$component",
    "$vulnerability|*",
    "*|$component"
  )
  foreach ($key in $keys) {
    if ($DecisionMap.ContainsKey($key)) {
      return $DecisionMap[$key]
    }
  }
  return $null
}

function Assert-OpenVexDecision($Decision) {
  $allowedStatuses = @("under_investigation", "affected", "not_affected", "fixed")
  $allowedJustifications = @(
    "component_not_present",
    "vulnerable_code_not_present",
    "vulnerable_code_not_in_execute_path",
    "vulnerable_code_cannot_be_controlled_by_adversary",
    "inline_mitigations_already_exist"
  )

  if ($allowedStatuses -notcontains $Decision.status) {
    throw "Unsupported OpenVEX status '$($Decision.status)'. Allowed values: $($allowedStatuses -join ', ')."
  }

  if ($Decision.status -eq "not_affected") {
    $justification = Get-PropertyValue $Decision "justification"
    $impactStatement = Get-PropertyValue $Decision "impact_statement"
    if ([string]::IsNullOrWhiteSpace($justification) -and [string]::IsNullOrWhiteSpace($impactStatement)) {
      throw "OpenVEX status 'not_affected' requires either 'justification' or 'impact_statement'."
    }
    if (-not [string]::IsNullOrWhiteSpace($justification) -and $allowedJustifications -notcontains $justification) {
      throw "Unsupported OpenVEX justification '$justification'. Allowed values: $($allowedJustifications -join ', ')."
    }
  }

  if ($Decision.status -eq "affected") {
    $actionStatement = Get-PropertyValue $Decision "action_statement"
    if ([string]::IsNullOrWhiteSpace($actionStatement)) {
      throw "OpenVEX status 'affected' requires 'action_statement'."
    }
  }
}

$trivyReport = Get-Content -LiteralPath $TrivyJsonPath -Raw | ConvertFrom-Json
$sbom = Get-Content -LiteralPath $SbomPath -Raw | ConvertFrom-Json
$decisions = Get-Content -LiteralPath $DecisionPath -Raw | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($ProductId)) {
  $metadataComponent = $sbom.metadata.component
  $ProductId = Get-PropertyValue $metadataComponent "purl"
  if ([string]::IsNullOrWhiteSpace($ProductId)) {
    $ProductId = Get-PropertyValue $metadataComponent "bom-ref"
  }
  if ([string]::IsNullOrWhiteSpace($ProductId)) {
    $ProductId = "urn:product:$($metadataComponent.name):$($metadataComponent.version)"
  }
}

$configuredAuthor = Get-PropertyValue $decisions "author"
if (-not [string]::IsNullOrWhiteSpace($configuredAuthor)) {
  $Author = $configuredAuthor
}

$configuredRole = Get-PropertyValue $decisions "role"
if (-not [string]::IsNullOrWhiteSpace($configuredRole)) {
  $Role = $configuredRole
}

$defaultStatus = "under_investigation"
$defaultStatusNotes = "New scanner finding. Triage is required before changing this VEX status."
if ($decisions.defaults) {
  $configuredDefaultStatus = Get-PropertyValue $decisions.defaults "status"
  $configuredDefaultNotes = Get-PropertyValue $decisions.defaults "status_notes"
  if (-not [string]::IsNullOrWhiteSpace($configuredDefaultStatus)) {
    $defaultStatus = $configuredDefaultStatus
  }
  if (-not [string]::IsNullOrWhiteSpace($configuredDefaultNotes)) {
    $defaultStatusNotes = $configuredDefaultNotes
  }
}

$decisionMap = @{}
foreach ($decision in Convert-ToArray $decisions.statements) {
  $vulnerability = Normalize-KeyPart (Get-PropertyValue $decision "vulnerability")
  $purl = Normalize-KeyPart (Get-PropertyValue $decision "purl")
  Assert-OpenVexDecision $decision
  $decisionMap["$vulnerability|$purl"] = $decision
}

$findingsByKey = [ordered]@{}
foreach ($result in Convert-ToArray $trivyReport.Results) {
  foreach ($vulnerability in Convert-ToArray $result.Vulnerabilities) {
    $vulnerabilityId = Get-PropertyValue $vulnerability "VulnerabilityID"
    if ([string]::IsNullOrWhiteSpace($vulnerabilityId)) {
      continue
    }

    $pkgIdentifier = Get-PropertyValue $vulnerability "PkgIdentifier"
    $purl = Get-PropertyValue $pkgIdentifier "PURL"
    if ([string]::IsNullOrWhiteSpace($purl)) {
      $purl = Get-PropertyValue $pkgIdentifier "BOMRef"
    }
    if ([string]::IsNullOrWhiteSpace($purl)) {
      $purl = Get-PropertyValue $vulnerability "PkgName"
    }

    $key = "$vulnerabilityId|$purl"
    if (-not $findingsByKey.Contains($key)) {
      $findingsByKey[$key] = [ordered]@{
        vulnerability = $vulnerabilityId
        purl = $purl
        package = Get-PropertyValue $vulnerability "PkgName"
        installedVersion = Get-PropertyValue $vulnerability "InstalledVersion"
        fixedVersion = Get-PropertyValue $vulnerability "FixedVersion"
        severity = Get-PropertyValue $vulnerability "Severity"
        primaryUrl = Get-PropertyValue $vulnerability "PrimaryURL"
      }
    }
  }
}

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$statements = @()

foreach ($finding in $findingsByKey.Values) {
  $decision = Get-Decision $decisionMap $finding.vulnerability $finding.purl
  if ($null -eq $decision) {
    $decision = [pscustomobject]@{
      status = $defaultStatus
      status_notes = $defaultStatusNotes
    }
  }

  Assert-OpenVexDecision $decision

  $vulnerabilityObject = [ordered]@{
    name = $finding.vulnerability
  }

  $productObject = [ordered]@{
    "@id" = $ProductId
  }
  if (-not [string]::IsNullOrWhiteSpace($finding.purl)) {
    $productObject.subcomponents = @(
      [ordered]@{
        "@id" = $finding.purl
      }
    )
  }

  $statement = [ordered]@{
    vulnerability = $vulnerabilityObject
    products = @($productObject)
    status = $decision.status
    timestamp = $timestamp
  }

  foreach ($propertyName in @("justification", "impact_statement", "action_statement", "action_statement_timestamp", "status_notes")) {
    $value = Get-PropertyValue $decision $propertyName
    if (-not [string]::IsNullOrWhiteSpace([string] $value)) {
      $statement[$propertyName] = $value
    }
  }

  $statements += $statement
}

$openVex = [ordered]@{
  "@context" = "https://openvex.dev/ns/v0.2.0"
  "@id" = "urn:uuid:$([guid]::NewGuid())"
  author = $Author
  role = $Role
  timestamp = $timestamp
  version = 1
  statements = $statements
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
  New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}

$openVexJson = $openVex | ConvertTo-Json -Depth 100
$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutputPath, $openVexJson, $utf8WithoutBom)

[pscustomobject]@{
  Product = $ProductId
  Findings = $findingsByKey.Count
  Statements = $statements.Count
  Output = (Resolve-Path -LiteralPath $OutputPath).Path
}
