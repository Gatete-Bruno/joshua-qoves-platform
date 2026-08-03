#!/usr/bin/env bash
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 <git-repo-url>"; exit 1; }
cd "$(dirname "$0")/.."
grep -rl 'repoURL: https://github.com/OWNER/qoves-platform.git\|repoURL: http://[^ ]*/platform.git' bootstrap apps \
  | xargs sed -i "s#repoURL: .*qoves-platform.git\$#repoURL: $1#; s#repoURL: http://.*/platform.git\$#repoURL: $1#"
git --no-pager diff --stat
