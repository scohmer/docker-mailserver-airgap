#!/bin/bash
# docker-mailserver user patches - air-gap / FIPS start-up adjustments.
# Executed by DMS at the end of container setup, before services start.
set -euo pipefail

# 1. Trust the internal CA chain (LDAPS, relay host, smtp_tls_CAfile)
if compgen -G '/usr/local/share/ca-certificates/internal/*.crt' > /dev/null; then
  update-ca-certificates --fresh > /dev/null
  echo "[user-patches] internal CA certificates installed"
fi

# 2. ClamAV: never contact the public ClamAV CDN
if [[ "${ENABLE_CLAMAV:-0}" == "1" && -f /etc/clamav/freshclam.conf ]]; then
  sed -i -E '/^(DatabaseMirror|PrivateMirror|ScriptedUpdates|Checks)\b/d' /etc/clamav/freshclam.conf
  if [[ -n "${CLAMAV_PRIVATE_MIRROR:-}" ]]; then
    printf 'PrivateMirror %s\nScriptedUpdates no\nChecks 4\n' "${CLAMAV_PRIVATE_MIRROR}" >> /etc/clamav/freshclam.conf
    echo "[user-patches] freshclam -> ${CLAMAV_PRIVATE_MIRROR}"
  else
    # No mirror: point at loopback so attempts fail fast locally; check once a day only.
    printf 'PrivateMirror http://127.0.0.1:9\nScriptedUpdates no\nChecks 1\n' >> /etc/clamav/freshclam.conf
    echo "[user-patches] freshclam disabled (manual signature import)"
  fi
fi

# 3. Record the active crypto providers in the start-up log (audit evidence)
echo "[user-patches] OpenSSL: $(openssl version)"
openssl list -providers 2>&1 | sed 's/^/[user-patches]   /'
