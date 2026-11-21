#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_ipa="${project_dir}/build/Source.ipa"
artifact_dir="${project_dir}/build/artifacts"

if [[ ! -s "${source_ipa}" ]]; then
  echo "IPA not found: ${source_ipa}" >&2
  exit 1
fi

artifact_ipa="${artifact_dir}/Source_Editor.ipa"
mkdir -p "${artifact_dir}"
cp "${source_ipa}" "${artifact_ipa}"
touch "${artifact_ipa}"
echo "Prepared ${artifact_ipa}"
