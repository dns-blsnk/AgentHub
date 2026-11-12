#!/bin/zsh
# Formats the code in place: swift format (layout, from .swift-format), then SwiftLint's autocorrect (.swiftlint.yml).
set -euo pipefail

cd "$(dirname "$0")/.."
swift format --in-place --recursive --parallel Sources Tests Package.swift
if command -v swiftlint >/dev/null; then
    swiftlint --fix --quiet
fi
