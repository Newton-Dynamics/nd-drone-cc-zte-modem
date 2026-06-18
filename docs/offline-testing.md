# Offline testing — no LTE hardware required

The full modem unlock flow can be tested on any Linux box with no LTE stick:

```
./nd_net_install.sh --test
```

Runs:
- `tests/test_registry.py` — 12 registry unit tests (lookup, validation,
  mutation, 0600 perms, secret masking).
- `tests/test_unlock_e2e.sh` — 7 end-to-end scenarios driving the **real**
  `zte_login.sh` against a mock modem.

## Mock modem

`tests/mock_zte_modem.py` is a stdlib HTTP server emulating the ZTE `goform`
API. It implements the **real** login (LD + SHA-256) and ENTER_PIN
(RD + MD5 AD) crypto, so `zte_login.sh` runs unmodified against it — the hashing
is genuinely exercised, not stubbed.

Configure the emulated device via env: `MOCK_IMEI`, `MOCK_IMSI`,
`MOCK_PASSWORD`, `MOCK_PIN`, `MOCK_IMEI_PREAUTH` (`0` hides IMEI before login to
exercise the last-good fallback path).

The e2e harness shims `logger` and `netbird` into a temp `PATH` so it runs
unprivileged and quiet.

## ⚠️ Gotcha — compact JSON

The mock **must** emit compact JSON (`{"k":"v"}`, no spaces). The unlock
script extracts values with `grep -oP '(?<="LD":")[^"]+'`, which assumes the
real device's compact output. Pretty-printed JSON (`json.dumps` default, with
`": "`) silently breaks **every** value extraction and the whole flow fails with
"Failed to extract LD value". This bit us once; keep the
`separators=(",", ":")` in `mock_zte_modem._json`.

## Driving the UI by hand on a dev box

```
ND_MODEM_REGISTRY=/tmp/dev.json ZTE_ENV_FILE=/tmp/z.env ND_NET_ENV_FILE=/tmp/n.env \
  ND_UI_BIND=127.0.0.1 python3 nd-net-ui.py
# open http://127.0.0.1:8088
```
