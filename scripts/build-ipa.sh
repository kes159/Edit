#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${project_dir}/build"
derived_dir="${build_dir}/DerivedData"
package_dir="${build_dir}/package"
app_path="${derived_dir}/Build/Products/Release-iphoneos/Source.app"
ipa_path="${build_dir}/Source.ipa"

xcodebuild \
  -project "${project_dir}/Source.xcodeproj" \
  -scheme Source \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "${derived_dir}" \
  -clonedSourcePackagesDirPath "${build_dir}/SourcePackages" \
  -skipPackageUpdates \
  -parallelizeTargets \
  -showBuildTimingSummary \
  CODE_SIGNING_ALLOWED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  DEBUG_INFORMATION_FORMAT=dwarf \
  build

rm -rf "${package_dir}"
mkdir -p "${package_dir}/Payload"
ditto "${app_path}" "${package_dir}/Payload/Source.app"
ditto -c -k --keepParent "${package_dir}/Payload" "${ipa_path}"
echo "Created: ${ipa_path}"
