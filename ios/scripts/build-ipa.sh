#!/usr/bin/env bash
# macOS + Xcode + XcodeGen. Creates an unsigned IPA for your existing signing workflow.
set -euo pipefail
trap 'printf "IPA build failed at line %s.\n" "$LINENO" >&2' ERR
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
cd "$repo_root"
command -v xcodegen >/dev/null || { printf "Install XcodeGen: brew install xcodegen\n" >&2; exit 1; }
xcodebuild -version
python3 -m venv .art-tools
.art-tools/bin/pip install Pillow==11.3.0
mkdir -p ios/www
cp index.html ios/www/index.html
# Replace only generated assets; never delete source files.
mkdir -p ios/www/assets
cp -R assets/. ios/www/assets/
.art-tools/bin/python ios/scripts/generate_artwork.py
python3 ios/scripts/inline_libs.py ios/www/index.html
cd ios
xcodegen generate
xcodebuild -project AIStudio.xcodeproj -scheme AIStudio -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
package_dir=$(mktemp -d "$repo_root/ios/build/ipa.XXXXXX")
mkdir -p "$package_dir/Payload"
cp -R build/Build/Products/Release-iphoneos/AIStudio.app "$package_dir/Payload/"
(
  cd "$package_dir"
  zip -qry "$package_dir/AIStudio.ipa" Payload
)
cp "$package_dir/AIStudio.ipa" "$repo_root/ios/build/AIStudio.ipa"
printf "Unsigned IPA: %s/ios/build/AIStudio.ipa\nSign it before installing on an iOS 17+ device.\n" "$repo_root"
