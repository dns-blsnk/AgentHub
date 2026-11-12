#!/bin/zsh
# Fails on any formatting or lint finding. scripts/format.sh fixes most of them.
set -euo pipefail

cd "$(dirname "$0")/.."
swift format lint --strict --recursive --parallel Sources Tests Package.swift
if ! command -v swiftlint >/dev/null; then
    echo "SwiftLint is not installed: brew install swiftlint" >&2
    exit 1
fi
swiftlint lint --strict --quiet
