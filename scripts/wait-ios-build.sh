#!/bin/bash
# Waits for the newest "Build IPA" run and prints the result plus compiler errors.
# Usage: bash scripts/wait-ios-build.sh [owner/repo]
GH="${GH:-/c/Program Files/GitHub CLI/gh.exe}"
R="${1:-pavel13801/vox}"
sleep 15
id=$("$GH" run list -R "$R" --workflow build.yml --limit 1 --json databaseId --jq '.[0].databaseId')
echo "run $id"
for i in $(seq 1 90); do
  s=$("$GH" run view "$id" -R "$R" --json status,conclusion --jq '.status+" "+.conclusion' 2>/dev/null)
  case "$s" in completed*) break;; esac
  sleep 20
done
echo "$s"
if [[ "$s" != "completed success" ]]; then
  "$GH" run view "$id" -R "$R" --log-failed 2>&1 | grep -E "error:" | sed 's/^.*Z //' | sed 's#/Users/runner/work/vox/vox/##' | sort -u | head -80
fi
