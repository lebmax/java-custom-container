# VEX automation example

This project shows a dependency-focused VEX workflow for Spring PetClinic:

1. Start with a CycloneDX SBOM.
2. Scan the SBOM with Trivy.
3. Convert scanner findings into an OpenVEX document.
4. Keep human or policy decisions in a separate `decisions.json` file.
5. Re-scan with the generated VEX to verify that the VEX is accepted by the scanner.

The key rule: VEX is not just another scanner output. A scanner can find candidate vulnerabilities, but VEX statements must represent an explicit exploitability assessment for this product and its dependencies.

## Files

- `decisions.example.json` — example triage decisions.
- `scripts/Invoke-VexPipeline.ps1` — full pipeline: Trivy scan, OpenVEX generation, Trivy scan with VEX.
- `scripts/Invoke-OpenVexFromTrivy.ps1` — converts Trivy JSON findings plus decisions into OpenVEX JSON.
- `scripts/invoke-vex-pipeline.sh` — shell version of the full pipeline.
- `scripts/invoke-openvex-from-trivy.sh` — shell version of the OpenVEX generator.
- `ci/github-actions-vex.yml` — CI example, kept outside `.github/workflows` so it does not modify repository workflow state.
- `ci/github-actions-vex-shell.yml` — CI example using the shell scripts.

## Local run

From the repository root:

```powershell
.\vex-automation\scripts\Invoke-VexPipeline.ps1 `
  -SbomPath .\sbom.cdx.json `
  -DecisionPath .\vex-automation\decisions.example.json
```

If PowerShell script execution is disabled:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\vex-automation\scripts\Invoke-VexPipeline.ps1 `
  -SbomPath .\sbom.cdx.json `
  -DecisionPath .\vex-automation\decisions.example.json
```

Linux, WSL, Git Bash:

```bash
chmod +x vex-automation/scripts/*.sh
./vex-automation/scripts/invoke-vex-pipeline.sh \
  --sbom ./sbom.cdx.json \
  --decisions ./vex-automation/decisions.example.json
```

Outputs:

```text
vex-automation/out/trivy-sbom-scan.json
vex-automation/out/petclinic.openvex.json
vex-automation/out/trivy-sbom-scan-with-vex.json
```

The script runs Trivy through Docker, so no local Trivy installation is required.

## Triage model

Each scanner finding is mapped by:

```text
vulnerability id + dependency PURL
```

Example:

```json
{
  "vulnerability": "CVE-2026-9828",
  "purl": "pkg:maven/ch.qos.logback/logback-core@1.5.32?type=jar",
  "status": "affected",
  "action_statement": "Upgrade logback-core to 1.5.33 or a later fixed version."
}
```

Allowed OpenVEX statuses:

- `under_investigation`
- `affected`
- `not_affected`
- `fixed`

For `not_affected`, provide a machine-readable `justification` whenever possible:

- `component_not_present`
- `vulnerable_code_not_present`
- `vulnerable_code_not_in_execute_path`
- `vulnerable_code_cannot_be_controlled_by_adversary`
- `inline_mitigations_already_exist`

## Using VEX with Trivy

After the pipeline generates `petclinic.openvex.json`, the scanner can consume it:

```powershell
docker run --rm `
  -v "${PWD}:/work" `
  aquasec/trivy:latest sbom `
  --vex /work/vex-automation/out/petclinic.openvex.json `
  --format table `
  /work/sbom.cdx.json
```

Only `not_affected` and `fixed` statements normally reduce scanner noise. `affected` and `under_investigation` are still useful because they document the current decision and required action.

## CI usage

Use `ci/github-actions-vex.yml` as a template. The usual flow is:

1. Generate or fetch `sbom.cdx.json`.
2. Run `Invoke-VexPipeline.ps1`.
3. Upload `petclinic.openvex.json` and scanner JSON reports as CI artifacts.
4. Fail the pipeline only on policy, for example if a `CRITICAL` vulnerability has no explicit decision.

Do not auto-mark new vulnerabilities as `not_affected`. Defaulting new findings to `under_investigation` is safer and auditable.
