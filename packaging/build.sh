#!/bin/bash
# Build an unsigned universal installer bundle. No credentials are packaged.
set -euo pipefail
# The monitor runs as a standard user and must be able to traverse payload dirs.
# Do not let a builder's private umask turn /usr/local/libexec into mode 700.
umask 022
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin ]] || { echo 'Build on macOS' >&2; exit 1; }
version=${1:-1.0.0}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version must be numeric x.y.z' >&2; exit 1; }
output=${2:-"$PWD/dist"}
mkdir -p "$output"
output=$(cd "$output" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
payload="$work/payload"
bundle="$work/Orbit-Installer"
mkdir -p "$payload/Library/PrivilegedHelperTools" "$payload/Library/LaunchDaemons" "$payload/usr/local/libexec" "$bundle"
sdk=$(xcrun --sdk macosx --show-sdk-path)
for arch in arm64 x86_64; do
  cache="$work/cache-$arch"
  swiftc -O -target "$arch-apple-macos13.0" -sdk "$sdk" -module-cache-path "$cache" \
    agent/main.swift -framework Security -o "$work/agent-$arch"
  swiftc -O -target "$arch-apple-macos13.0" -sdk "$sdk" -module-cache-path "$cache" \
    agent/FocusTracker.swift agent/ForegroundMonitor.swift -framework AppKit -framework IOKit -o "$work/monitor-$arch"
  swiftc -O -target "$arch-apple-macos13.0" -sdk "$sdk" -module-cache-path "$cache" \
    packaging/Setup.swift -o "$work/setup-$arch"
  swiftc -O -target "$arch-apple-macos13.0" -sdk "$sdk" -module-cache-path "$cache" \
    packaging/Uninstall.swift -o "$work/uninstall-$arch"
done
lipo -create "$work/agent-arm64" "$work/agent-x86_64" -output "$payload/Library/PrivilegedHelperTools/orbit-agent"
lipo -create "$work/monitor-arm64" "$work/monitor-x86_64" -output "$payload/usr/local/libexec/orbit-foreground"
lipo -create "$work/setup-arm64" "$work/setup-x86_64" -output "$payload/usr/local/libexec/orbit-setup"
lipo -create "$work/uninstall-arm64" "$work/uninstall-x86_64" -output "$payload/usr/local/libexec/orbit-uninstall"
for binary in "$payload/Library/PrivilegedHelperTools/orbit-agent" "$payload/usr/local/libexec/"*; do
  chmod 755 "$binary"
  codesign --force --sign - "$binary"
  codesign --verify --strict "$binary"
  lipo "$binary" -verify_arch arm64 x86_64
done
cp agent/com.side-forge.orbit.agent.plist "$payload/Library/LaunchDaemons/"
chmod 644 "$payload/Library/LaunchDaemons/"*.plist
pkgbuild --root "$payload" --ownership recommended --install-location / \
  --identifier com.side-forge.orbit.installer --version "$version" "$bundle/Orbit.pkg"
cp "$payload/usr/local/libexec/orbit-setup" "$bundle/OrbitSetup"
cp "$payload/usr/local/libexec/orbit-uninstall" "$bundle/OrbitUninstall"
cp packaging/Install-Orbit.command "$bundle/Install Orbit.command"
cp packaging/Uninstall-Orbit.command "$bundle/Uninstall Orbit.command"
cp packaging/README.txt "$bundle/README.txt"
chmod 755 "$bundle/OrbitSetup" "$bundle/OrbitUninstall" "$bundle/Install Orbit.command" "$bundle/Uninstall Orbit.command"
ditto -c -k --keepParent "$bundle" "$output/Orbit-Installer.zip"
(cd "$output" && shasum -a 256 Orbit-Installer.zip > Orbit-Installer.zip.sha256)
# Upload this source archive to the Chrome Web Store first. Google supplies
# the real extension ID; do not use an unpacked/developer ID for deployment.
(cd browser/chrome && /usr/bin/zip -q "$work/Orbit-Chrome-WebStore.zip" manifest.json background.js managed_schema.json)
cp "$work/Orbit-Chrome-WebStore.zip" "$output/Orbit-Chrome-WebStore.zip"
echo "Created $output/Orbit-Installer.zip"
echo "Chrome Web Store upload: $output/Orbit-Chrome-WebStore.zip"
