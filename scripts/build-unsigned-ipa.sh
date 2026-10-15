#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
mkdir -p build

if ! xcodebuild -version; then
  echo 'A full Xcode 26 or newer installation is required.' >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/opennomi-build.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

xcodebuild -resolvePackageDependencies \
  -project OpenNomi.xcodeproj \
  -scheme OpenNomi \
  -clonedSourcePackagesDirPath "$work_dir/SourcePackages" \
  -onlyUsePackageVersionsFromResolvedFile \
  2>&1 | tee build/xcodebuild.log

xcodebuild archive \
  -project OpenNomi.xcodeproj \
  -scheme OpenNomi \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath "$work_dir/OpenNomi.xcarchive" \
  -derivedDataPath "$work_dir/DerivedData" \
  -clonedSourcePackagesDirPath "$work_dir/SourcePackages" \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  DEVELOPMENT_TEAM='' \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  2>&1 | tee -a build/xcodebuild.log

app_path="$work_dir/OpenNomi.xcarchive/Products/Applications/OpenNomi.app"
test -d "$app_path"
mkdir -p "$work_dir/staging/Payload"
/usr/bin/ditto "$app_path" "$work_dir/staging/Payload/OpenNomi.app"
ipa_path="$work_dir/OpenNomi-unsigned.ipa"
(
  cd "$work_dir/staging"
  /usr/bin/zip -qry "$ipa_path" Payload
)
/usr/bin/unzip -t "$ipa_path" > /dev/null
mv "$ipa_path" build/OpenNomi-unsigned.ipa

python3 scripts/verify-ipa.py build/OpenNomi-unsigned.ipa
(
  cd build
  /usr/bin/shasum -a 256 OpenNomi-unsigned.ipa > OpenNomi-unsigned.ipa.sha256
)
