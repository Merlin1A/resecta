#!/bin/bash
# Regenerate Xcode project and restore shared schemes that xcodegen overwrites.
set -e
xcodegen generate
mkdir -p ResectaApp.xcodeproj/xcshareddata/xcschemes
cp xcschemes/*.xcscheme ResectaApp.xcodeproj/xcshareddata/xcschemes/
echo "Project regenerated. Shared schemes restored."
