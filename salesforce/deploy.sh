#!/bin/zsh
# Validates or deploys the study-tour metadata, filling in organisation values from the config file.
# Usage: salesforce/deploy.sh validate|deploy <org-alias> [prerequisites]
#   prerequisites — deploy the package with the pre-existing Fulbright fields (salesforce/prerequisites) instead
set -euo pipefail
cd "$(dirname "$0")"
MODE=${1:?usage: deploy.sh validate|deploy <org-alias>}
ORG=${2:?usage: deploy.sh validate|deploy <org-alias>}
CONFIG=../config/studytours.config.json
[[ -f $CONFIG ]] || { echo "Missing $CONFIG — copy config/studytours.config.example.json and fill it in."; exit 1; }
KB=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["knowledgeBaseURL"])' "$CONFIG")
TMP=$(mktemp -d)
SRC=.
[[ "${3:-}" == "prerequisites" ]] && SRC=prerequisites
cp -R "$SRC/sfdx-project.json" "$SRC/force-app" "$TMP/"
grep -rl "__KNOWLEDGE_BASE_URL__" "$TMP/force-app" | while read -r f; do
  /usr/bin/sed -i '' "s|__KNOWLEDGE_BASE_URL__|${KB}|g" "$f"
done
cd "$TMP"
case $MODE in
  validate) sf project deploy validate --source-dir force-app --target-org "$ORG" ;;
  deploy)   sf project deploy start --source-dir force-app --target-org "$ORG" ;;
  *) echo "mode must be validate or deploy"; exit 1 ;;
esac
