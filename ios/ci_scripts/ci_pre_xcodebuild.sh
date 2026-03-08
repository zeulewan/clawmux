#!/bin/sh
# Xcode Cloud pre-build script: install XcodeGen and generate the .xcodeproj

set -e

echo "Installing XcodeGen..."
brew install xcodegen

echo "Generating Xcode project from project.yml..."
cd "$CI_PRIMARY_REPOSITORY_PATH/ios"
xcodegen generate

echo "Done."
