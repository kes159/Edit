#!/usr/bin/env bash
# Mac Catalyst로 macOS용 Source Editor 앱을 빌드하고 ZIP으로 묶습니다.
# 결과: build/Source_Editor_macOS.zip (압축을 풀면 "Source Editor.app")
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${project_dir}/build"
derived_dir="${build_dir}/DerivedData-macos"
package_dir="${build_dir}/macos-package"
built_app="${derived_dir}/Build/Products/Release-maccatalyst/Source.app"
app_name="Source Editor.app"
packaged_app="${package_dir}/${app_name}"
zip_path="${build_dir}/Source_Editor_macOS.zip"

xcodebuild \
  -project "${project_dir}/Source.xcodeproj" \
  -scheme Source \
  -configuration Release \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "${derived_dir}" \
  -clonedSourcePackagesDirPath "${build_dir}/SourcePackages" \
  -skipPackageUpdates \
  -parallelizeTargets \
  -showBuildTimingSummary \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  DEBUG_INFORMATION_FORMAT=dwarf \
  build

if [[ ! -d "${built_app}" ]]; then
  echo "빌드 결과를 찾을 수 없습니다: ${built_app}" >&2
  echo "Products 폴더 내용:" >&2
  ls -la "${derived_dir}/Build/Products" >&2 || true
  exit 1
fi

rm -rf "${package_dir}"
mkdir -p "${package_dir}"
ditto "${built_app}" "${packaged_app}"

# 서명 없는 앱은 Apple 실리콘 Mac에서 실행되지 않으므로 임시(ad-hoc) 서명을 합니다.
# 개발자 인증서가 아니어서 Gatekeeper 경고는 남습니다(README의 macOS 설치 방법 참고).
codesign --force --deep --sign - "${packaged_app}"
codesign --verify --deep --strict "${packaged_app}"

# ditto로 압축해야 서명과 심볼릭 링크가 보존됩니다.
rm -f "${zip_path}"
ditto -c -k --keepParent "${packaged_app}" "${zip_path}"
echo "Created: ${zip_path}"
