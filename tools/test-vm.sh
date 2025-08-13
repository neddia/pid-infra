#!/usr/bin/env bash
set -euo pipefail
find .. -type f \( -name "*.sh" -o -name "*.service" -o -name "*.timer" -o -name "compose.yml" -o -name "*.env*" -o -name "*.md" \) -print0 | xargs -0 sed -i 's/\r$//'
