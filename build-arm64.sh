#!/bin/bash
set -e

cd /app
flutter pub get
flutter build linux --release

VERSION=$(grep '^version:' pubspec.yaml | cut -d ' ' -f 2)
PACKAGE_DIR="build/linux/sakiengine-${VERSION}-Linux-arm64"

mkdir -p "${PACKAGE_DIR}"/{DEBIAN,opt/sakiengine,usr/share/applications,usr/share/icons/hicolor/512x512/apps}

cp -r build/linux/*/release/bundle/* "${PACKAGE_DIR}/opt/sakiengine/"
cp -r assets/linux/DEBIAN/* "${PACKAGE_DIR}/DEBIAN/"
chmod 0755 "${PACKAGE_DIR}/DEBIAN/postinst"
chmod 0755 "${PACKAGE_DIR}/DEBIAN/postrm"

cat > "${PACKAGE_DIR}/DEBIAN/control" << EOF
Package: sakiengine
Version: ${VERSION}
Section: x11
Priority: optional
Architecture: arm64
Essential: no
Installed-Size: 34648
Maintainer: madoka773 <valigarmanda55@gmail.com>
Description: A cross platform danmaku video player.
Homepage: https://github.com/MCDFsteve/sakiengine
Depends: ffmpeg, libass9
EOF

cp assets/linux/io.github.MCDFsteve.sakiengine.desktop "${PACKAGE_DIR}/usr/share/applications/"
cp assets/images/logo512.png "${PACKAGE_DIR}/usr/share/icons/hicolor/512x512/apps/io.github.MCDFsteve.sakiengine.png"

cd build/linux
dpkg-deb --build --root-owner-group "sakiengine-${VERSION}-Linux-arm64" 