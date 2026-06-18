#!/usr/bin/env bash
# End-to-end test: drive the REAL zte_login.sh against the mock ZTE modem,
# with the device registry as the secret source. No hardware required.
#
# Scenarios:
#   1. Pre-auth IMEI exposed; registry has matching stick + SIM      -> unlock
#   2. Pre-auth IMEI hidden; last-good login fallback finds password -> unlock
#   3. Wrong PIN in registry                                          -> ENTER_PIN fails
#   4. Stick not registered, no .env fallback                        -> login fails
#
# Run: bash tests/test_unlock_e2e.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
MOCK_PID=""
trap 'rm -rf "$WORK"; [[ -n "${MOCK_PID:-}" ]] && kill "$MOCK_PID" 2>/dev/null' EXIT

pass=0; fail=0
ok()   { echo "  PASS: $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $*"; fail=$((fail+1)); sed 's/^/    | /' "$WORK/logger.out" 2>/dev/null; }

REG="python3 $ROOT/nd-modem-registry.py"

# --- fake logger/netbird so the script runs unprivileged & quiet -------------
mkdir -p "$WORK/bin"
cat >"$WORK/bin/logger" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == "-t" ]] && shift 2
echo "\$*" >> "$WORK/logger.out"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/bin/netbird"
chmod +x "$WORK/bin/logger" "$WORK/bin/netbird"
export PATH="$WORK/bin:$PATH"

# start_mock VAR=val VAR=val ... — launches the mock with the given env, sets PORT.
start_mock() {
  : >"$WORK/mock.log"; : >"$WORK/mock.port"
  env "$@" MOCK_PORT=0 python3 "$ROOT/tests/mock_zte_modem.py" \
      >"$WORK/mock.port" 2>"$WORK/mock.log" &
  MOCK_PID=$!
  local tries=0 line=""
  while (( tries < 100 )); do
    line="$(head -1 "$WORK/mock.port" 2>/dev/null)"
    [[ "$line" == PORT\ * ]] && break
    sleep 0.05; tries=$((tries+1))
  done
  PORT="${line#PORT }"
  [[ -n "$PORT" ]] || { echo "mock failed to start"; cat "$WORK/mock.log"; exit 1; }
}
stop_mock() { [[ -n "$MOCK_PID" ]] && { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }; MOCK_PID=""; }

# run_unlock DB [ZTE_PASSWORD] [ZTE_PIN] -> echoes rc of zte_login.sh
run_unlock() {
  : >"$WORK/logger.out"
  ZTE_HOST="127.0.0.1:$PORT" \
  ND_MODEM_REGISTRY="$1" \
  ZTE_REGISTRY_CMD="python3 $ROOT/nd-modem-registry.py" \
  ZTE_PASSWORD="${2:-}" ZTE_PIN="${3:-}" \
    bash "$ROOT/zte_login.sh" >"$WORK/run.out" 2>&1
  echo $?
}
logged() { grep -q -- "$1" "$WORK/logger.out"; }

echo "== Scenario 1: pre-auth IMEI + matching registry => unlock =="
DB="$WORK/db1.json"; rm -f "$DB"
ND_MODEM_REGISTRY="$DB" $REG add-stick --imei 350000000000001 --password StickPwOne --label A >/dev/null
ND_MODEM_REGISTRY="$DB" $REG add-sim   --imsi 262011234567890 --pin 1234 --label vf >/dev/null
start_mock MOCK_IMEI=350000000000001 MOCK_IMSI=262011234567890 MOCK_PASSWORD=StickPwOne MOCK_PIN=1234
rc=$(run_unlock "$DB")
stop_mock
if [[ "$rc" == "0" ]] && logged "SIM unlocked"; then ok "unlocked with registry secrets (rc=$rc)"; else bad "expected unlock, rc=$rc"; fi
logged "Found registry password for IMEI 350000000000001" && ok "used registry stick password" || bad "no registry password match logged"
logged "Found registry PIN for IMSI 262011234567890" && ok "used registry SIM PIN" || bad "no registry PIN match logged"

echo "== Scenario 2: pre-auth IMEI hidden => last-good fallback => unlock =="
DB="$WORK/db2.json"; rm -f "$DB"
ND_MODEM_REGISTRY="$DB" $REG add-stick --imei 350000000000009 --password StickPwNine --label N >/dev/null
ND_MODEM_REGISTRY="$DB" $REG add-sim   --imsi 262011234567890 --pin 1234 >/dev/null
start_mock MOCK_IMEI=350000000000009 MOCK_IMSI=262011234567890 MOCK_PASSWORD=StickPwNine MOCK_PIN=1234 MOCK_IMEI_PREAUTH=0
ND_MODEM_REGISTRY="$DB" $REG record-login --host "127.0.0.1:$PORT" --imei 350000000000009 --ts 2026-06-18T00:00:00+00:00 >/dev/null
rc=$(run_unlock "$DB")
stop_mock
if [[ "$rc" == "0" ]] && logged "SIM unlocked"; then ok "unlocked via last-good fallback (rc=$rc)"; else bad "expected unlock via fallback, rc=$rc"; fi
logged "IMEI not readable pre-auth" && ok "took the pre-auth-hidden path" || bad "expected pre-auth-hidden log"

echo "== Scenario 3: wrong PIN in registry => ENTER_PIN failure =="
DB="$WORK/db3.json"; rm -f "$DB"
ND_MODEM_REGISTRY="$DB" $REG add-stick --imei 350000000000001 --password StickPwOne >/dev/null
ND_MODEM_REGISTRY="$DB" $REG add-sim   --imsi 262011234567890 --pin 0000 >/dev/null   # wrong
start_mock MOCK_IMEI=350000000000001 MOCK_IMSI=262011234567890 MOCK_PASSWORD=StickPwOne MOCK_PIN=1234
rc=$(run_unlock "$DB")
stop_mock
if [[ "$rc" != "0" ]] && logged "SIM unlocking failed"; then ok "wrong PIN correctly rejected (rc=$rc)"; else bad "expected ENTER_PIN failure, rc=$rc"; fi

echo "== Scenario 4: unregistered stick, no .env fallback => login fails =="
DB="$WORK/db4.json"; rm -f "$DB"
ND_MODEM_REGISTRY="$DB" $REG add-sim --imsi 262011234567890 --pin 1234 >/dev/null  # SIM only, no stick
start_mock MOCK_IMEI=350000000000077 MOCK_IMSI=262011234567890 MOCK_PASSWORD=Unknown MOCK_PIN=1234
rc=$(run_unlock "$DB")
stop_mock
if [[ "$rc" != "0" ]] && { logged "No candidate login passwords" || logged "login failed"; }; then
  ok "login refused for unregistered stick (rc=$rc)"; else bad "expected failure, rc=$rc"; fi

echo
echo "RESULT: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
