#!/bin/sh
# Packages flutter build linux --release into a .deb and a portable tarball,
# for this machine's processor (x64 or arm64). Run on Ubuntu after the
# bundle exists at build/linux/<arch>/release/bundle. The remote server's
# VERSION and servers.json, when built into build/remote/, go beside the
# executable (lib/remote/remote_binaries.dart); the app downloads the
# builds they name.
#
#   sh tool/package_linux_deb.sh            the standard build
#   sh tool/package_linux_deb.sh --channel  the channel build (built with
#                                           CAOCODE_CHANNEL=true in the
#                                           environment and as a dart-define):
#                                           its files end in -channel, and it
#                                           depends on WebKitGTK, for its
#                                           login window
set -eu

edition=
webkit=
case "${1:-}" in
  --channel) edition=-channel; webkit=", libwebkit2gtk-4.1-0" ;;
  "") ;;
  *) echo "Unknown argument: $1" >&2; exit 1 ;;
esac

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
version=$(sed -n 's/^version:[[:space:]]*//p' "$root/pubspec.yaml")
marketing=${version%%+*}
case "$(uname -m)" in
  x86_64) arch=x64; package_arch=amd64 ;;
  aarch64 | arm64) arch=arm64; package_arch=arm64 ;;
  *) echo "Not built for $(uname -m)" >&2; exit 1 ;;
esac
bundle="$root/build/linux/$arch/release/bundle"

if [ ! -x "$bundle/caocode" ]; then
  echo "No bundle at $bundle. Run: flutter build linux --release" >&2
  exit 1
fi

if [ -f "$root/build/remote/servers.json" ]; then
  rm -rf "$bundle/remote"
  mkdir -p "$bundle/remote"
  cp "$root/build/remote/VERSION" "$root/build/remote/servers.json" "$bundle/remote/"
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/opt/caocode" \
  "$stage/usr/bin" \
  "$stage/usr/share/applications" \
  "$stage/usr/share/icons/hicolor/128x128/apps" \
  "$stage/DEBIAN"

cp -a "$bundle/." "$stage/opt/caocode/"
cp "$root/assets/branding/app_icon.png" \
  "$stage/usr/share/icons/hicolor/128x128/apps/caocode.png"

cat > "$stage/usr/bin/caocode" << 'EOF'
#!/bin/sh
exec /opt/caocode/caocode "$@"
EOF
chmod 755 "$stage/usr/bin/caocode"

cat > "$stage/usr/share/applications/caocode.desktop" << 'EOF'
[Desktop Entry]
Name=Caocode
Comment=Desktop app for Claude Code
Exec=caocode %U
Icon=caocode
Terminal=false
Type=Application
Categories=Development;
StartupWMClass=dev.caocode.desktop
EOF

# libgtk-3-0 is what the engine links. libblkid1 and liblzma5 are the
# extra libraries Flutter's Linux bundle expects on the system.
cat > "$stage/DEBIAN/control" << EOF
Package: caocode
Version: ${marketing}
Section: devel
Priority: optional
Architecture: ${package_arch}
Depends: libgtk-3-0, libblkid1, liblzma5${webkit}
Maintainer: Caocode <noreply@caocode.dev>
Homepage: https://caocode.dev
Description: Caocode desktop for Linux
 A desktop UI for Claude Code, with a fast IDE built in.
EOF

out="$root/build/installers"
mkdir -p "$out"
name="Caocode-${marketing}-linux-${package_arch}${edition}"
dpkg-deb --build --root-owner-group "$stage" "$out/$name.deb"
tar -C "$bundle" -czf "$out/$name.tar.gz" .
echo "Wrote $out/$name.deb"
echo "Wrote $out/$name.tar.gz"
