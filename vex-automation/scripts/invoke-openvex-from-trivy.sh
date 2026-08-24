#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  invoke-openvex-from-trivy.sh \
    --trivy-json vex-automation/out/trivy-sbom-scan.json \
    --sbom sbom.cdx.json \
    --decisions vex-automation/decisions.example.json \
    --output vex-automation/out/petclinic.openvex.json

Optional:
  --product-id <id>
  --author <name>
  --role <role>
EOF
}

TRIVY_JSON_PATH=""
SBOM_PATH=""
DECISION_PATH=""
OUTPUT_PATH=""
PRODUCT_ID=""
AUTHOR="Unknown Author"
ROLE="Document Creator"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --trivy-json)
      TRIVY_JSON_PATH="${2:-}"
      shift 2
      ;;
    --sbom)
      SBOM_PATH="${2:-}"
      shift 2
      ;;
    --decisions)
      DECISION_PATH="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="${2:-}"
      shift 2
      ;;
    --product-id)
      PRODUCT_ID="${2:-}"
      shift 2
      ;;
    --author)
      AUTHOR="${2:-}"
      shift 2
      ;;
    --role)
      ROLE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$TRIVY_JSON_PATH" || -z "$SBOM_PATH" || -z "$DECISION_PATH" || -z "$OUTPUT_PATH" ]]; then
  usage >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required for structured JSON processing." >&2
  exit 1
fi

python3 - "$TRIVY_JSON_PATH" "$SBOM_PATH" "$DECISION_PATH" "$OUTPUT_PATH" "$PRODUCT_ID" "$AUTHOR" "$ROLE" <<'PY'
import json
import os
import sys
import uuid
from datetime import datetime, timezone

trivy_json_path, sbom_path, decision_path, output_path, product_id, author, role = sys.argv[1:8]

ALLOWED_STATUSES = {
    "under_investigation",
    "affected",
    "not_affected",
    "fixed",
}

ALLOWED_JUSTIFICATIONS = {
    "component_not_present",
    "vulnerable_code_not_present",
    "vulnerable_code_not_in_execute_path",
    "vulnerable_code_cannot_be_controlled_by_adversary",
    "inline_mitigations_already_exist",
}


def load_json(path):
    with open(path, "r", encoding="utf-8-sig") as handle:
        return json.load(handle)


def as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def key_part(value):
    if value is None:
        return "*"
    value = str(value).strip()
    return value if value else "*"


def validate_decision(decision):
    status = decision.get("status")
    if status not in ALLOWED_STATUSES:
        raise SystemExit(
            f"Unsupported OpenVEX status '{status}'. "
            f"Allowed values: {', '.join(sorted(ALLOWED_STATUSES))}."
        )

    if status == "not_affected":
        justification = decision.get("justification")
        impact_statement = decision.get("impact_statement")
        if not justification and not impact_statement:
            raise SystemExit(
                "OpenVEX status 'not_affected' requires either "
                "'justification' or 'impact_statement'."
            )
        if justification and justification not in ALLOWED_JUSTIFICATIONS:
            raise SystemExit(
                f"Unsupported OpenVEX justification '{justification}'. "
                f"Allowed values: {', '.join(sorted(ALLOWED_JUSTIFICATIONS))}."
            )

    if status == "affected" and not decision.get("action_statement"):
        raise SystemExit("OpenVEX status 'affected' requires 'action_statement'.")


def get_product_id(sbom, explicit_product_id):
    if explicit_product_id:
        return explicit_product_id

    component = sbom.get("metadata", {}).get("component", {})
    for field in ("purl", "bom-ref"):
        if component.get(field):
            return component[field]
    name = component.get("name", "unknown")
    version = component.get("version", "unknown")
    return f"urn:product:{name}:{version}"


trivy_report = load_json(trivy_json_path)
sbom = load_json(sbom_path)
decisions = load_json(decision_path)

product_id = get_product_id(sbom, product_id)
author = decisions.get("author") or author
role = decisions.get("role") or role

defaults = decisions.get("defaults", {})
default_status = defaults.get("status", "under_investigation")
default_status_notes = defaults.get(
    "status_notes",
    "New scanner finding. Triage is required before changing this VEX status.",
)

decision_map = {}
for decision in as_list(decisions.get("statements")):
    validate_decision(decision)
    vulnerability = key_part(decision.get("vulnerability"))
    purl = key_part(decision.get("purl"))
    decision_map[f"{vulnerability}|{purl}"] = decision


def find_decision(vulnerability_id, purl):
    vulnerability = key_part(vulnerability_id)
    component = key_part(purl)
    for key in (f"{vulnerability}|{component}", f"{vulnerability}|*", f"*|{component}"):
        if key in decision_map:
            return decision_map[key]
    return {
        "status": default_status,
        "status_notes": default_status_notes,
    }


findings = {}
for result in as_list(trivy_report.get("Results")):
    for vulnerability in as_list(result.get("Vulnerabilities")):
        vulnerability_id = vulnerability.get("VulnerabilityID")
        if not vulnerability_id:
            continue

        pkg_identifier = vulnerability.get("PkgIdentifier") or {}
        purl = (
            pkg_identifier.get("PURL")
            or pkg_identifier.get("BOMRef")
            or vulnerability.get("PkgName")
            or ""
        )
        key = f"{vulnerability_id}|{purl}"
        findings.setdefault(
            key,
            {
                "vulnerability": vulnerability_id,
                "purl": purl,
            },
        )

timestamp = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
statements = []

for finding in findings.values():
    decision = find_decision(finding["vulnerability"], finding["purl"])
    validate_decision(decision)

    product = {"@id": product_id}
    if finding["purl"]:
        product["subcomponents"] = [{"@id": finding["purl"]}]

    statement = {
        "vulnerability": {"name": finding["vulnerability"]},
        "products": [product],
        "status": decision["status"],
        "timestamp": timestamp,
    }

    for field in (
        "justification",
        "impact_statement",
        "action_statement",
        "action_statement_timestamp",
        "status_notes",
    ):
        value = decision.get(field)
        if value:
            statement[field] = value

    statements.append(statement)

openvex = {
    "@context": "https://openvex.dev/ns/v0.2.0",
    "@id": f"urn:uuid:{uuid.uuid4()}",
    "author": author,
    "role": role,
    "timestamp": timestamp,
    "version": 1,
    "statements": statements,
}

output_dir = os.path.dirname(output_path)
if output_dir:
    os.makedirs(output_dir, exist_ok=True)

with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(openvex, handle, ensure_ascii=False, indent=2)
    handle.write("\n")

print(f"Product: {product_id}")
print(f"Findings: {len(findings)}")
print(f"Statements: {len(statements)}")
print(f"Output: {os.path.abspath(output_path)}")
PY
