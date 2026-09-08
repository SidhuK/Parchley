#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
swift_format="${SWIFT_FORMAT_BIN:-}"
if [[ -z "$swift_format" ]]; then
  swift_format="$(xcrun --find swift-format)"
fi

[[ -x "$swift_format" ]] || {
  print -u2 "swift-format is required; set SWIFT_FORMAT_BIN to its path"
  exit 2
}

"$swift_format" lint --strict --recursive --parallel \
  "$repo_root/Parchley" \
  "$repo_root/Packages/ParchleyDomain/Sources" \
  "$repo_root/Packages/ParchleyEngine/Sources" \
  "$repo_root/Packages/ParchleyMarkdown/Sources" \
  "$repo_root/ParchleyTests" \
  "$repo_root/ParchleyUITests" \
  "$repo_root/Packages/ParchleyDomain/Tests" \
  "$repo_root/Packages/ParchleyEngine/Tests" \
  "$repo_root/Packages/ParchleyMarkdown/Tests"
