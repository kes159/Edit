#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_ipa="${project_dir}/build/AltSourceStudio.ipa"
artifact_dir="${project_dir}/build/artifacts"

if [[ ! -s "${source_ipa}" ]]; then
  echo "IPA not found: ${source_ipa}" >&2
  exit 1
fi

# This is the last preparation step before artifact upload. The upload itself
# takes additional seconds, so its exact completion time cannot be known yet.
stamp_kst="$(TZ=Asia/Seoul date '+%Y%m%d-%H%M%S')"
artifact_name="AltSourceStudio-unsigned-${stamp_kst}-KST"
artifact_ipa="${artifact_dir}/${artifact_name}.ipa"
mkdir -p "${artifact_dir}"
cp "${source_ipa}" "${artifact_ipa}"

# upload-artifact@v4 writes the file's UTC time into a ZIP DOS timestamp with
# no timezone field. macOS treats that timestamp as local time on extraction.
# Encode the KST wall-clock time as UTC for this upload copy so Finder shows
# the intended KST time after extracting the downloaded artifact ZIP.
touch_stamp="${stamp_kst:0:8}${stamp_kst:9:4}.${stamp_kst:13:2}"
TZ=UTC touch -t "${touch_stamp}" "${artifact_ipa}"

encoded_time="$(TZ=UTC date -r "${artifact_ipa}" '+%Y%m%d-%H%M%S')"
if [[ "${encoded_time}" != "${stamp_kst}" ]]; then
  echo "Artifact timestamp mismatch: ${encoded_time} != ${stamp_kst}" >&2
  exit 1
fi

echo "Prepared ${artifact_ipa} (${stamp_kst} KST)"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'artifact_name=%s\n' "${artifact_name}"
    printf 'ipa_path=%s\n' "${artifact_ipa}"
  } >> "${GITHUB_OUTPUT}"
fi
