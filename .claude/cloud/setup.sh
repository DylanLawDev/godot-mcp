#!/bin/bash
# Claude Code cloud environment setup script for this repo.
#
# Not run from the repo: paste this into the environment's "Setup script" field
# at claude.ai/code. It runs once as root on Ubuntu 24.04 and the result is
# cached, so sessions start with Godot already installed as `godot4` (the name
# run_tests.sh and run_scenario.sh default to).
#
# Keep GODOT_VERSION in sync with .github/workflows/tests.yml.
set -euo pipefail
GODOT_VERSION=4.6.1
base="Godot_v${GODOT_VERSION}-stable_linux.x86_64"
command -v unzip >/dev/null || (apt-get update && apt-get install -y unzip)
curl -fSL -o /tmp/godot.zip \
	"https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/${base}.zip"
unzip -q /tmp/godot.zip -d /tmp
install -m 755 "/tmp/${base}" /usr/local/bin/godot4
rm -f /tmp/godot.zip "/tmp/${base}"
godot4 --version
