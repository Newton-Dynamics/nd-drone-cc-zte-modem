#!/usr/bin/env bash
# this file goes to /opt/zte/zte_http.sh
set -Eeuo pipefail
LOGTAG="nd-zte"
# Resolve the directory of this script (handles symlinks too)
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"

# Prefer an override via ZTE_ENV_FILE; else default to .env next to the script
ENV_FILE="${ZTE_ENV_FILE:-$SCRIPT_DIR/.env}"

# Optionally export all variables defined in .env to child processes
if [[ -r "$ENV_FILE" ]]; then
  /usr/bin/logger -t "$LOGTAG" "Loading env file: $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
else
  /usr/bin/logger -t "$LOGTAG" "WARN: .env not found or not readable at $ENV_FILE (PWD=$(pwd))"
  exit 1
fi


# --- at this point all vars from .env are exported ---

child="$SCRIPT_DIR/zte_login.sh"
/usr/bin/logger -t "$LOGTAG" "Starting child: $child"
"$child" arg1 arg2  # inherits the exported env

