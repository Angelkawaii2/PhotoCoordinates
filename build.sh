#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p PhotoCoordinates.app/Contents/MacOS PhotoCoordinates.app/Contents/Resources
swiftc -swift-version 5 -parse-as-library Sources/*.swift -o PhotoCoordinates.app/Contents/MacOS/PhotoCoordinates -framework SwiftUI -framework Photos -framework MapKit -framework ImageIO -framework WebKit
cp Info.plist PhotoCoordinates.app/Contents/Info.plist
cp Assets/AppIcon.icns PhotoCoordinates.app/Contents/Resources/AppIcon.icns
codesign --force --deep --sign - PhotoCoordinates.app
