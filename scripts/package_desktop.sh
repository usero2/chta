#!/usr/bin/env bash
set -euo pipefail

platform=$1
flutter_arch=${2:-}
cd "$(dirname "$0")/.."
source_root=$PWD
app_root=$source_root/apps/flutter_app
version=$(sed -n 's/^version: //p' "$app_root/pubspec.yaml")
name="chta-${version/+/-build}-$platform"
mkdir -p dist-desktop
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

build_native() {
  cargo build --locked --release -p cht-core "$@"
  cargo build --locked --release --manifest-path rust/crates/native_mesh/Cargo.toml "$@"
}

case "$platform" in
  linux-x86_64|linux-aarch64)
    build_native
    (
      cd "$app_root"
      flutter pub get --enforce-lockfile
      flutter build linux --release --no-pub
    )
    bundle="$app_root/build/linux/$flutter_arch/release/bundle"
    install -m 755 target/release/libcht_core.so rust/crates/native_mesh/target/release/libcht_mesh.so "$bundle"
    install -m 644 LICENSE "$bundle/LICENSE"
    for binary in "$bundle/chta" "$bundle"/libcht_*.so "$bundle"/lib/*.so; do
      if ldd "$binary" | grep -F 'not found'; then
        echo "Unresolved dependency in $(basename "$binary")" >&2
        exit 1
      fi
    done
    dbus-run-session -- bash -ec '
      printf "ci-only-password" | gnome-keyring-daemon --unlock
      export XDG_DATA_HOME="$1/state"
      python3 "$2/scripts/smoke_desktop_vault.py" "$3/libcht_core.so"
      status=0
      timeout 8 xvfb-run -a "$3/chta" || status=$?
      test "$status" -eq 124
      echo "Verified native Flutter window starts"
    ' smoke "$scratch" "$source_root" "$bundle"
    mv "$bundle" "$scratch/$name"
    tar -czf "dist-desktop/$name.tar.gz" -C "$scratch" "$name"
    ;;
  macos-universal)
    export MACOSX_DEPLOYMENT_TARGET=12.0
    for arch in aarch64-apple-darwin x86_64-apple-darwin; do
      rustup target add "$arch"
      build_native --target "$arch"
    done
    (
      cd "$app_root"
      flutter pub get --enforce-lockfile
      flutter build macos --release --no-pub
    )
    app="$app_root/build/macos/Build/Products/Release/chta.app"
    for crate in core mesh; do
      base_dir=target
      if [[ "$crate" == mesh ]]; then
        base_dir=rust/crates/native_mesh/target
      fi
      library="libcht_$crate.dylib"
      lipo -create -output "$app/Contents/Frameworks/$library" \
        "$base_dir/aarch64-apple-darwin/release/$library" \
        "$base_dir/x86_64-apple-darwin/release/$library"
      codesign --force --sign - "$app/Contents/Frameworks/$library"
    done
    codesign --force --sign - --entitlements "$app_root/macos/Runner/Release.entitlements" "$app"
    codesign --verify --deep --strict "$app"
    lipo -verify_arch x86_64 arm64 "$app/Contents/MacOS/chta"
    for library in "$app/Contents/Frameworks/"libcht*.dylib; do
      lipo -verify_arch x86_64 arm64 "$library"
    done
    python3 "$source_root/scripts/smoke_desktop_vault.py" "$app/Contents/Frameworks/libcht_core.dylib"
    mkdir "$scratch/disk"
    ditto "$app" "$scratch/disk/chta.app"
    cp LICENSE "$scratch/disk/LICENSE"
    ln -s /Applications "$scratch/disk/Applications"
    hdiutil create -quiet -fs HFS+ -format UDZO -volname chta -srcfolder "$scratch/disk" "dist-desktop/$name.dmg"
    hdiutil verify "dist-desktop/$name.dmg"
    ;;
  *)
    echo "Unknown desktop platform: $platform" >&2
    exit 1
    ;;
esac
