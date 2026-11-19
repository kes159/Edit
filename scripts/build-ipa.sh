#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${project_dir}/build"
derived_dir="${build_dir}/DerivedData"
package_dir="${build_dir}/package"
app_path="${derived_dir}/Build/Products/Release-iphoneos/AltSourceStudio.app"
ipa_path="${build_dir}/AltSourceStudio.ipa"

xcodebuild \
  -project "${project_dir}/AltSourceStudio.xcodeproj" \
  -scheme AltSourceStudio \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "${derived_dir}" \
  CODE_SIGNING_ALLOWED=NO \
  build

rm -rf "${package_dir}"
mkdir -p "${package_dir}/Payload"
ditto "${app_path}" "${package_dir}/Payload/AltSourceStudio.app"
ditto -c -k --keepParent "${package_dir}/Payload" "${ipa_path}"
echo "Created: ${ipa_path}"
