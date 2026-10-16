#!/usr/bin/env bash
# =============================================================================
# fetch-offline-bundle.sh
# -----------------------------------------------------------------------------
# Run on the CONNECTED staging host (ideally the same OS major/minor as the
# enclave host, e.g. Rocky/RHEL 10.2, with Podman). Collects everything the
# air-gapped docker-mailserver deployment needs into one verified bundle:
#
#   images/     DMS upstream image (+ FIPS-provider image) as docker-archive tars
#   source/     DMS release source (offline docs, reference mailserver.env)
#   fips/       OpenSSL FIPS provider source, signature, CMVP Security Policy
#   clamav/     ClamAV signatures (cvdupdate)
#   spamassassin/  SpamAssassin rules (optional)
#   rpms/       EL8 host RPMs: modular local repo + GPG keys + install-offline.sh
#   tools/      testssl.sh / docker-compose binary (optional)
#   deploy/     docker-compose.yml, .env.example (+ .env if present), configs, Dockerfile.fips, docs
#   MANIFEST.txt, SHA256SUMS, versions.txt, env-diff.txt
#
# Usage:  ./fetch-offline-bundle.sh [options]
#   -t, --dms-tag TAG          DMS release tag              (default: $DMS_TAG or 16.0.1)
#   -o, --out DIR              output directory             (default: ./offline-bundle-<tag>-<date>)
#   -f, --fips-version VER     OpenSSL FIPS provider version (default: auto from image's Debian release)
#       --no-fips              skip building the FIPS-provider image (Option A)
#       --no-clamav            skip ClamAV signatures
#       --spamassassin         include SpamAssassin rules
#       --no-rpms              skip host RPM download
#       --no-tools             skip testssl.sh / docker-compose binary
#       --skip-gpg             do NOT fail if the OpenSSL GPG signature can't be verified
#       --no-tar               don't create the final single .tar
#       --only-signatures      refresh run: ClamAV (+SA) signatures only
#   -h, --help
#
# Environment overrides: DMS_IMAGE_REPO, TESTSSL_VERSION, COMPOSE_VERSION,
#   OPENSSL_TRUSTED_FPRS (space-separated primary-key fingerprints you accept;
#     default: OpenSSL doc/fingerprints.txt at the release tag + master),
#   GPG_KEYSERVER, RPM_PACKAGES, RPM_EPEL_PACKAGES,
#   RPM_EL_RELEASE (default 8.10), RPM_BUILDER_IMAGE (default rockylinux:<release>),
#   TARGET_RPM_QA (file with `rpm -qa --qf '%{NAME}\n'` from the enclave host)
# =============================================================================
set -Eeuo pipefail

# ----------------------------------------------------------------------------- defaults
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DMS_TAG="${DMS_TAG:-16.0.1}"
DMS_IMAGE_REPO="${DMS_IMAGE_REPO:-ghcr.io/docker-mailserver/docker-mailserver}"
FIPS_IMAGE_REPO="${FIPS_IMAGE_REPO:-localhost/docker-mailserver-fips}"
OPENSSL_FIPS_VERSION="${OPENSSL_FIPS_VERSION:-}"
TESTSSL_VERSION="${TESTSSL_VERSION:-3.2.4}"
COMPOSE_VERSION="${COMPOSE_VERSION:-}"          # empty = skip docker-compose binary
GPG_KEYSERVER="${GPG_KEYSERVER:-hkps://keyserver.ubuntu.com}"
OPENSSL_TRUSTED_FPRS="${OPENSSL_TRUSTED_FPRS:-}"
RPM_EL_RELEASE="${RPM_EL_RELEASE:-8.10}"
# Rocky Linux builder for Rocky/Alma/RHEL-compatible targets. For a RHEL 8 target, run
# on a subscribed RHEL host with RPM_BUILDER_IMAGE=registry.access.redhat.com/ubi8/ubi:8.10
# (UBI containers inherit the host's RHEL entitlement -> full RHEL repos).
RPM_BUILDER_IMAGE="${RPM_BUILDER_IMAGE:-docker.io/rockylinux/rockylinux:${RPM_EL_RELEASE}}"
TARGET_RPM_QA="${TARGET_RPM_QA:-}"
# EL8 default network backend is CNI (containernetworking-plugins), not netavark.
RPM_PACKAGES="${RPM_PACKAGES:-podman podman-docker containernetworking-plugins container-selinux firewalld chrony openssl bind-utils nmap nmap-ncat}"
RPM_EPEL_PACKAGES="${RPM_EPEL_PACKAGES:-podman-compose swaks}"

DO_FIPS=1 DO_CLAMAV=1 DO_SA=0 DO_RPMS=1 DO_TOOLS=1 DO_TAR=1 SKIP_GPG=0 ONLY_SIGS=0
OUT=""

# ----------------------------------------------------------------------------- helpers
c_info=$'\e[1;34m' c_ok=$'\e[1;32m' c_warn=$'\e[1;33m' c_err=$'\e[1;31m' c_off=$'\e[0m'
[[ -t 1 ]] || { c_info='' c_ok='' c_warn='' c_err='' c_off=''; }
log()  { printf '%s[*]%s %s\n' "$c_info" "$c_off" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_warn" "$c_off" "$*" >&2; WARNINGS+=("$*"); }
die()  { printf '%s[x]%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }
WARNINGS=()
trap 'die "failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

usage() { sed -n '/^# Usage:/,/^# =====/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0; }

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# curl with retries; first URL that works wins
fetch() { # fetch <dest> <url> [<fallback-url>...]
  local dest="$1"; shift
  for url in "$@"; do
    if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$dest" "$url"; then
      log "downloaded $(basename "$dest")  <- $url"; return 0
    fi
  done
  rm -f "$dest"; return 1
}

podman_q() { podman "$@" 2>/dev/null; }

# ----------------------------------------------------------------------------- args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--dms-tag)       DMS_TAG="$2"; shift 2 ;;
    -o|--out)           OUT="$2"; shift 2 ;;
    -f|--fips-version)  OPENSSL_FIPS_VERSION="$2"; shift 2 ;;
    --no-fips)          DO_FIPS=0; shift ;;
    --no-clamav)        DO_CLAMAV=0; shift ;;
    --spamassassin)     DO_SA=1; shift ;;
    --no-rpms)          DO_RPMS=0; shift ;;
    --no-tools)         DO_TOOLS=0; shift ;;
    --skip-gpg)         SKIP_GPG=1; shift ;;
    --no-tar)           DO_TAR=0; shift ;;
    --only-signatures)  ONLY_SIGS=1; shift ;;
    -h|--help)          usage ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[[ "$DMS_TAG" =~ ^(latest|edge)$ ]] && die "refusing floating tag '$DMS_TAG' - pin a release (e.g. 16.0.1)"
DMS_IMAGE="${DMS_IMAGE_REPO}:${DMS_TAG}"
FIPS_IMAGE="${FIPS_IMAGE_REPO}:${DMS_TAG}"
STAMP="$(date -u +%Y%m%d)"
OUT="${OUT:-${SCRIPT_DIR}/offline-bundle-${DMS_TAG}-${STAMP}}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="${OUT}/.work"
mkdir -p "$WORK"

# ----------------------------------------------------------------------------- prerequisites
log "checking prerequisites"
for c in curl sha256sum tar podman; do need "$c"; done
[[ $DO_FIPS -eq 1 && $ONLY_SIGS -eq 0 ]] && need gpg
[[ $DO_CLAMAV -eq 1 ]] && need python3
curl -fsS -o /dev/null --connect-timeout 10 https://ghcr.io/ || die "no internet access (ghcr.io unreachable)"
ok "prerequisites present"

# ============================================================================= 1. DMS image
pull_dms_image() {
  log "pulling ${DMS_IMAGE}"
  mkdir -p "$OUT/images"
  podman pull "$DMS_IMAGE" >/dev/null
  local digest id
  digest="$(podman image inspect --format '{{.Digest}}' "$DMS_IMAGE")"
  id="$(podman image inspect --format '{{.Id}}' "$DMS_IMAGE")"
  printf '%s\n  registry digest: %s\n  image id:        %s\n' "$DMS_IMAGE" "$digest" "$id" > "$OUT/images/dms-${DMS_TAG}.ids"

  log "recording component versions inside the image"
  podman run --rm --entrypoint bash "$DMS_IMAGE" -c '
    echo "debian_version : $(cat /etc/debian_version)"
    echo "openssl        : $(openssl version)"
    echo "postfix        : $(postconf -d -h mail_version 2>/dev/null)"
    echo "dovecot        : $(dovecot --version 2>/dev/null)"
    echo "clamav         : $(clamscan --version 2>/dev/null)"
    echo "spamassassin   : $(spamassassin --version 2>/dev/null | head -n1)"
    echo "opendkim       : $(opendkim -V 2>/dev/null | head -n1)"
    echo "rspamd         : $(rspamd --version 2>/dev/null | head -n1)"
  ' > "$OUT/versions.txt"
  sed 's/^/    /' "$OUT/versions.txt"

  DEBIAN_MAJOR="$(sed -n 's/^debian_version : \([0-9]*\).*/\1/p' "$OUT/versions.txt")"
  [[ -n "$DEBIAN_MAJOR" ]] || die "could not determine Debian release of the image"
  grep -q 'dovecot *: 2\.3' "$OUT/versions.txt" && \
    warn "image ships Dovecot 2.3 - config/dovecot.cf uses 2.4 syntax and must be ported back"

  log "saving ${DMS_IMAGE}"
  podman save --format docker-archive -o "$OUT/images/dms-${DMS_TAG}.tar" "$DMS_IMAGE"
  ok "DMS image saved"
}

# ============================================================================= 2. DMS source/docs
fetch_dms_source() {
  mkdir -p "$OUT/source"
  local tgz="$OUT/source/docker-mailserver-v${DMS_TAG}.tar.gz"
  fetch "$tgz" "https://github.com/docker-mailserver/docker-mailserver/archive/refs/tags/v${DMS_TAG}.tar.gz" \
    || die "could not download DMS source for v${DMS_TAG}"

  # Reference mailserver.env -> diff against our .env
  tar -xzf "$tgz" -C "$WORK" "docker-mailserver-${DMS_TAG}/mailserver.env" 2>/dev/null || true
  local ref="$WORK/docker-mailserver-${DMS_TAG}/mailserver.env"
  local envf="$SCRIPT_DIR/.env"; [[ -f "$envf" ]] || envf="$SCRIPT_DIR/.env.example"
  if [[ -f "$ref" && -f "$envf" ]]; then
    cp "$ref" "$OUT/source/mailserver.env.reference"
    {
      echo "# Variables in DMS v${DMS_TAG} mailserver.env MISSING from .env (consider adding):"
      comm -23 <(grep -oE '^[A-Z0-9_]+' "$ref" | sort -u) <(grep -oE '^[A-Z0-9_]+' "$envf" | sort -u)
      echo
      echo "# Variables in .env NOT in DMS v${DMS_TAG} (compose-only, hook vars, or obsolete):"
      comm -13 <(grep -oE '^[A-Z0-9_]+' "$ref" | sort -u) <(grep -oE '^[A-Z0-9_]+' "$envf" | sort -u)
    } > "$OUT/env-diff.txt"
    ok "env diff written to env-diff.txt"
  else
    warn "reference mailserver.env not found in source tarball - diff .env manually"
  fi
  ok "DMS source/docs saved"
}

# ============================================================================= 3. FIPS provider image
select_fips_version() {
  if [[ -z "$OPENSSL_FIPS_VERSION" ]]; then
    case "$DEBIAN_MAJOR" in
      13) OPENSSL_FIPS_VERSION=3.1.2 ;;
      12) OPENSSL_FIPS_VERSION=3.0.9
          warn "Debian 12 image: only the 3.0.x provider fits (cert #4282, FIPS 140-2, HISTORICAL since 2026-09-21). Prefer a DMS tag based on Debian 13." ;;
      *)  die "unsupported Debian release '$DEBIAN_MAJOR' - pass --fips-version explicitly" ;;
    esac
  fi
  case "$OPENSSL_FIPS_VERSION" in
    3.1.2)       CMVP_CERT=4985 ;;
    3.0.8|3.0.9) CMVP_CERT=4282 ;;
    *)           CMVP_CERT="" ; warn "unknown CMVP cert for OpenSSL ${OPENSSL_FIPS_VERSION} - download its Security Policy manually" ;;
  esac
  DEBIAN_TAG="${DEBIAN_MAJOR}-slim"
  log "FIPS provider: OpenSSL ${OPENSSL_FIPS_VERSION} (CMVP #${CMVP_CERT:-?}), build base debian:${DEBIAN_TAG}"
}

fetch_openssl_source() {
  mkdir -p "$OUT/fips"
  local v="$OPENSSL_FIPS_VERSION" series="${OPENSSL_FIPS_VERSION%.*}" f="openssl-${OPENSSL_FIPS_VERSION}.tar.gz"
  local site="https://openssl-library.org/source" gh="https://github.com/openssl/openssl/releases/download/openssl-${v}"
  for ext in "" .sha256 .asc; do
    fetch "$OUT/fips/${f}${ext}" "${gh}/${f}${ext}" "${site}/old/${series}/${f}${ext}" "${site}/${f}${ext}" \
      || die "could not download ${f}${ext}"
  done

  # --- checksum
  local want got
  want="$(awk '{print $1; exit}' "$OUT/fips/${f}.sha256")"
  got="$(sha256sum "$OUT/fips/${f}" | awk '{print $1}')"
  [[ "$want" == "$got" ]] || die "SHA-256 mismatch for ${f}"
  ok "SHA-256 verified: ${got}"

  # --- signature (isolated keyring)
  # Trust anchor: fingerprints OpenSSL publishes in doc/fingerprints.txt (at the
  # release tag and on master), unless OPENSSL_TRUSTED_FPRS is set explicitly.
  # Keys: openssl-library.org/source/pubkeys.asc, then $GPG_KEYSERVER.
  export GNUPGHOME; GNUPGHOME="$(mktemp -d /tmp/fob-gnupg.XXXXXX)"   # short path: gpg socket length limit
  local status="$WORK/gpg-status.txt" trusted="$OPENSSL_TRUSTED_FPRS" ref fp
  if [[ -z "$trusted" ]]; then
    for ref in "openssl-${v}" master; do
      fetch "$OUT/fips/fingerprints-${ref}.txt" "https://raw.githubusercontent.com/openssl/openssl/${ref}/doc/fingerprints.txt" || true
    done
    trusted="$(cat "$OUT"/fips/fingerprints-*.txt 2>/dev/null \
               | grep -E '^[0-9A-F]{4}( [0-9A-F]{4}){9}$' | tr -d ' ' | sort -u | tr '\n' ' ')"
  fi
  if fetch "$OUT/fips/openssl-pubkeys.asc" "${site}/pubkeys.asc"; then
    gpg --batch --import "$OUT/fips/openssl-pubkeys.asc" 2>/dev/null || true
  fi
  for fp in $trusted; do
    gpg --batch --list-keys "$fp" >/dev/null 2>&1 \
      || timeout 60 gpg --batch --keyserver "$GPG_KEYSERVER" --recv-keys "$fp" >/dev/null 2>&1 || true
  done

  local verified=0 fpr=""
  if gpg --batch --status-file "$status" --verify "$OUT/fips/${f}.asc" "$OUT/fips/${f}" 2> "$OUT/fips/gpg-verify.log"; then
    # VALIDSIG field 12 = primary key fingerprint (field 3 may be a subkey)
    fpr="$(awk '$2=="VALIDSIG"{print $12; exit}' "$status")"
    echo "signer primary fingerprint: $fpr" >> "$OUT/fips/gpg-verify.log"
    if [[ -n "$fpr" && " $trusted " == *" $fpr "* ]]; then
      verified=1
      if grep -qE 'KEYREVOKED|REVKEYSIG|EXPKEYSIG|KEYEXPIRED' "$status"; then
        warn "OpenSSL signing key ${fpr} is now expired/revoked (key roll-over). The signature itself is good and predates the revocation - record this in your evidence (fips/gpg-verify.log)."
      fi
      gpg --batch --export --armor "$fpr" > "$OUT/fips/openssl-signer-${fpr}.asc"
      ok "GPG signature verified; signer ${fpr} is an OpenSSL-published release key"
    else
      echo "signer ${fpr:-?} is NOT in the trusted fingerprint list" >> "$OUT/fips/gpg-verify.log"
    fi
  fi
  if [[ $verified -eq 0 ]]; then
    if [[ $SKIP_GPG -eq 1 ]]; then
      warn "GPG verification FAILED for ${f} - continuing because --skip-gpg was given (see fips/gpg-verify.log)"
    else
      cat "$OUT/fips/gpg-verify.log" >&2
      die "GPG verification failed for ${f} (use --skip-gpg only with ISSM approval)"
    fi
  fi
  gpgconf --kill all >/dev/null 2>&1 || true; rm -rf "$GNUPGHOME"; unset GNUPGHOME

  # --- CMVP certificate Security Policy (ATO evidence)
  if [[ -n "${CMVP_CERT:-}" ]]; then
    fetch "$OUT/fips/140sp${CMVP_CERT}.pdf" \
      "https://csrc.nist.gov/CSRC/media/projects/cryptographic-module-validation-program/documents/security-policies/140sp${CMVP_CERT}.pdf" \
      || warn "could not download Security Policy 140sp${CMVP_CERT}.pdf - get it from csrc.nist.gov manually"
    printf 'https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/%s\n' "$CMVP_CERT" \
      > "$OUT/fips/CMVP-certificate-URL.txt"
  fi
}

build_fips_image() {
  [[ -f "$SCRIPT_DIR/Dockerfile.fips" ]] || die "Dockerfile.fips not found next to this script"
  local ctx="$WORK/fips-build"
  rm -rf "$ctx"; mkdir -p "$ctx"
  cp "$SCRIPT_DIR/Dockerfile.fips" "$ctx/"
  cp "$OUT/fips/openssl-${OPENSSL_FIPS_VERSION}.tar.gz" "$ctx/"

  log "building ${FIPS_IMAGE} (this compiles OpenSSL; several minutes)"
  podman build --pull=missing --format docker -f "$ctx/Dockerfile.fips" \
    --build-arg "DMS_TAG=${DMS_TAG}" \
    --build-arg "DEBIAN_TAG=${DEBIAN_TAG}" \
    --build-arg "OPENSSL_FIPS_VERSION=${OPENSSL_FIPS_VERSION}" \
    -t "$FIPS_IMAGE" "$ctx" > "$OUT/fips/build.log" 2>&1 \
    || { tail -n 40 "$OUT/fips/build.log" >&2; die "FIPS image build failed (see fips/build.log)"; }
  ok "FIPS image built"

  # --- runtime checks with the real deployment openssl.cnf
  local cnf="$SCRIPT_DIR/docker-data/dms/fips/openssl.cnf"
  if [[ -f "$cnf" ]]; then
    log "verifying provider with deployment openssl.cnf"
    podman run --rm --entrypoint bash -v "$cnf:/etc/ssl/openssl.cnf:ro,Z" "$FIPS_IMAGE" -c '
      set -e
      openssl list -providers
      echo test | openssl dgst -sha256 >/dev/null && echo "sha256: OK"
      if echo test | openssl dgst -md5 >/dev/null 2>&1; then echo "md5: ALLOWED (NOT FIPS)"; exit 1; else echo "md5: blocked (expected)"; fi
    ' > "$OUT/fips/provider-check.txt" 2>&1 \
      || { cat "$OUT/fips/provider-check.txt" >&2; die "FIPS provider runtime check failed"; }
    ok "provider active, MD5 blocked"

    log "testing ClamAV under the FIPS provider"
    if podman run --rm --entrypoint bash -v "$cnf:/etc/ssl/openssl.cnf:ro,Z" "$FIPS_IMAGE" -c '
         echo "harmless test file" > /tmp/t && sigtool --md5 /tmp/t && sigtool --sha256 /tmp/t \
           && { [ -z "$(ls /var/lib/clamav/*.c[lv]d 2>/dev/null)" ] || clamscan --no-summary /tmp/t; }' > "$OUT/fips/clamav-fips-check.txt" 2>&1; then
      ok "ClamAV scans with the FIPS provider active"
    else
      warn "ClamAV FAILED under the FIPS provider (see fips/clamav-fips-check.txt) - see setup-instructions.md §4.5"
    fi
  fi

  podman image inspect --format "${FIPS_IMAGE}  image id: {{.Id}}" "$FIPS_IMAGE" > "$OUT/images/dms-fips-${DMS_TAG}.ids"
  log "saving ${FIPS_IMAGE}"
  podman save --format docker-archive -o "$OUT/images/dms-fips-${DMS_TAG}.tar" "$FIPS_IMAGE"
  cp "$SCRIPT_DIR/Dockerfile.fips" "$OUT/fips/"
  ok "FIPS image saved"
}

# ============================================================================= 4. ClamAV
fetch_clamav() {
  log "fetching ClamAV signatures with cvdupdate"
  local venv="$WORK/cvd-venv" db="$OUT/clamav/db"
  mkdir -p "$db"
  local py; py="$( { command -v python3.12 python3.11 python3.9 python3 2>/dev/null || true; } | head -n1)"   # EL8: python3 is 3.6
  [[ -x "$venv/bin/cvd" ]] || { "$py" -m venv "$venv" && "$venv/bin/pip" install -q --upgrade pip cvdupdate; }
  # Keep cvdupdate's own config/state inside the work dir
  export HOME="$WORK/cvd-home"; mkdir -p "$HOME"
  "$venv/bin/cvd" config set --dbdir "$db" >/dev/null
  "$venv/bin/cvd" update || die "cvd update failed (rate-limited? run at most once per day)"
  export HOME="$REAL_HOME"
  for f in main.cvd daily.cvd bytecode.cvd; do
    [[ -s "$db/$f" ]] || die "ClamAV database $f missing after update"
  done
  tar -czf "$OUT/clamav/clamav-db-${STAMP}.tgz" -C "$db" .
  rm -rf "$db"
  ok "ClamAV signatures: clamav/clamav-db-${STAMP}.tgz"
}

# ============================================================================= 5. SpamAssassin
fetch_spamassassin() {
  log "fetching SpamAssassin rules with sa-update inside ${DMS_IMAGE}"
  mkdir -p "$OUT/spamassassin"
  podman image exists "$DMS_IMAGE" || podman pull "$DMS_IMAGE" >/dev/null
  podman run --rm --entrypoint bash -v "$OUT/spamassassin:/out:Z" "$DMS_IMAGE" -c "
    sa-update -v; rc=\$?
    [ \$rc -le 1 ] || { echo 'sa-update failed rc='\$rc; exit \$rc; }
    tar -czf /out/sa-rules-${STAMP}.tgz -C /var/lib/spamassassin .
  " || die "SpamAssassin rule download failed"
  ok "SpamAssassin rules: spamassassin/sa-rules-${STAMP}.tgz"
}

# ============================================================================= 6. Host RPMs (EL8)
# Built inside an EL8 container (works from any staging host with Podman):
#  * dnf download --resolve --alldeps for the requested packages (+EPEL)
#  * "sibling closure": packages installed on the target that come from the same
#    source RPMs as anything downloaded (e.g. rpm-libs -> python3-rpm,
#    rpm-build-libs) - without these an older target can't upgrade the shared libs
#  * createrepo_c + AppStream modules.yaml (modifyrepo_c) - REQUIRED on EL8,
#    otherwise modular filtering hides podman/container-selinux (container-tools)
#  * the GPG keys needed to install with gpgcheck=1
fetch_rpms() {
  log "building EL${RPM_EL_RELEASE} offline repo in ${RPM_BUILDER_IMAGE}"
  local dir="$OUT/rpms" helper="$WORK/build-el-repo.sh" qa_mount=()
  mkdir -p "$dir"
  if [[ -n "$TARGET_RPM_QA" ]]; then
    [[ -s "$TARGET_RPM_QA" ]] || die "TARGET_RPM_QA file not found or empty: $TARGET_RPM_QA"
    qa_mount=(-v "$(cd "$(dirname "$TARGET_RPM_QA")" && pwd)/$(basename "$TARGET_RPM_QA"):/target-rpm-qa.txt:ro,Z")
  else
    warn "TARGET_RPM_QA not set - sibling packages computed from the builder image's package set; supply 'rpm -qa --qf \"%{NAME}\\n\"' from the enclave host for an exact match"
  fi
  cat > "$helper" <<'INNER'
#!/bin/bash
set -euo pipefail
. /etc/os-release; echo "builder: $PRETTY_NAME"
dnf -y -q install dnf-plugins-core createrepo_c xz >/dev/null
if [ -n "$EPEL_PKGS" ]; then
  dnf -y -q install epel-release >/dev/null 2>&1 \
    || dnf -y -q install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${VERSION_ID%%.*}.noarch.rpm" >/dev/null
fi
dnf -q makecache >/dev/null
# shellcheck disable=SC2086
dnf download -q --resolve --alldeps --arch x86_64,noarch --destdir /out $PKGS $EPEL_PKGS
# sibling closure
rpm -qp --qf '%{SOURCERPM}\n' /out/*.rpm 2>/dev/null | sort -u > /tmp/srpms
if [ -s /target-rpm-qa.txt ]; then sort -u /target-rpm-qa.txt > /tmp/inst; else rpm -qa --qf '%{NAME}\n' | sort -u > /tmp/inst; fi
# shellcheck disable=SC2046
dnf -q repoquery --latest-limit 1 --arch x86_64,noarch --qf '%{name} %{sourcerpm}' $(cat /tmp/inst) 2>/dev/null \
  | awk 'NR==FNR{s[$1];next} ($2 in s){print $1}' /tmp/srpms - | sort -u > /tmp/sibs
echo "sibling packages added: $(wc -l < /tmp/sibs)"
# shellcheck disable=SC2046
[ -s /tmp/sibs ] && dnf download -q --resolve --arch x86_64,noarch --destdir /out $(cat /tmp/sibs)
# repo + module metadata
m=$(ls /var/cache/dnf/*appstream*/repodata/*modules.yaml* 2>/dev/null | head -1)
[ -n "$m" ] || { echo "AppStream modules.yaml not found" >&2; exit 1; }
case "$m" in *.xz) xz -dc "$m";; *.gz) gzip -dc "$m";; *) cat "$m";; esac > /tmp/modules.yaml
rm -rf /out/repodata
createrepo_c -q /out
modifyrepo_c --mdtype=modules /tmp/modules.yaml /out/repodata >/dev/null
mkdir -p /out/gpg-keys && cp /etc/pki/rpm-gpg/RPM-GPG-KEY-* /out/gpg-keys/
dnf -q module list --enabled 2>/dev/null | awk '/^container-tools/{print "module stream: "$1":"$2}'
INNER
  podman pull -q "$RPM_BUILDER_IMAGE" >/dev/null
  podman run --rm -v "$dir:/out:Z" -v "$helper:/build-el-repo.sh:ro,Z" "${qa_mount[@]}" \
    -e PKGS="$RPM_PACKAGES" -e EPEL_PKGS="$RPM_EPEL_PACKAGES" \
    "$RPM_BUILDER_IMAGE" bash /build-el-repo.sh > "$WORK/rpm-build.log" 2>&1 \
    || { tail -n 30 "$WORK/rpm-build.log" >&2; die "EL${RPM_EL_RELEASE} RPM repo build failed"; }
  { echo "builder image: $RPM_BUILDER_IMAGE"; grep -E '^(builder|module stream|sibling)' "$WORK/rpm-build.log"
    echo "packages: $RPM_PACKAGES"; echo "EPEL packages: $RPM_EPEL_PACKAGES"; } > "$dir/BUILT-ON.txt"

  # Enclave-side installer
  cat > "$dir/install-offline.sh" <<EOF
#!/bin/bash
# Install the container host packages from this offline EL${RPM_EL_RELEASE} repo (run as root).
set -euo pipefail
HERE="\$(cd "\$(dirname "\$0")" && pwd)"
rpm --import "\$HERE"/gpg-keys/RPM-GPG-KEY-*
dnf -y --disablerepo='*' --repofrompath=offline,"\$HERE" --setopt=offline.gpgcheck=1 \\
    install $RPM_PACKAGES $RPM_EPEL_PACKAGES
EOF
  chmod 755 "$dir/install-offline.sh"
  ok "RPMs: $(find "$dir" -name '*.rpm' | wc -l) packages ($(du -sh "$dir" | cut -f1)); install with rpms/install-offline.sh"
}

# ============================================================================= 7. Tools
fetch_tools() {
  mkdir -p "$OUT/tools"
  if [[ -n "$TESTSSL_VERSION" ]]; then
    fetch "$OUT/tools/testssl.sh-${TESTSSL_VERSION}.tar.gz" \
      "https://github.com/testssl/testssl.sh/archive/refs/tags/v${TESTSSL_VERSION}.tar.gz" \
      && ok "testssl.sh ${TESTSSL_VERSION}" \
      || warn "could not download testssl.sh v${TESTSSL_VERSION}"
  fi
  if [[ -n "$COMPOSE_VERSION" ]]; then
    local base="https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}"
    if fetch "$OUT/tools/docker-compose-linux-x86_64" "$base/docker-compose-linux-x86_64" \
       && fetch "$OUT/tools/docker-compose-linux-x86_64.sha256" "$base/docker-compose-linux-x86_64.sha256"; then
      (cd "$OUT/tools" && sha256sum -c docker-compose-linux-x86_64.sha256 >/dev/null) \
        || die "docker-compose checksum mismatch"
      chmod 755 "$OUT/tools/docker-compose-linux-x86_64"
      ok "docker-compose ${COMPOSE_VERSION}"
    else
      warn "could not download docker-compose v${COMPOSE_VERSION}"
    fi
  fi
}

# ============================================================================= 8. Deployment kit
copy_deploy_kit() {
  log "copying deployment kit"
  local d="$OUT/deploy"
  mkdir -p "$d/docker-data/dms"
  for f in docker-compose.yml .env .env.example README.md setup-instructions.md Dockerfile.fips fetch-offline-bundle.sh; do
    [[ -f "$SCRIPT_DIR/$f" ]] && cp -p "$SCRIPT_DIR/$f" "$d/"
  done
  for sub in config fips; do
    [[ -d "$SCRIPT_DIR/docker-data/dms/$sub" ]] && cp -rp "$SCRIPT_DIR/docker-data/dms/$sub" "$d/docker-data/dms/"
  done
  # Never ship keys/certs or mail data in the bundle
  rm -rf "$d/docker-data/dms/certs" "$d/docker-data/dms/mail-"*
  if grep -qE '^(LDAP_BIND_PW|RELAY_PASSWORD|SASLAUTHD_LDAP_PASSWORD)=.+' "$d/.env" 2>/dev/null; then
    warn ".env in the bundle contains credentials - handle the media accordingly"
  fi
  ok "deployment kit in deploy/"
}

# ============================================================================= 9. Manifest
write_manifest() {
  log "writing manifest and checksums"
  {
    echo "docker-mailserver offline bundle"
    echo "created (UTC): $(date -u '+%Y-%m-%d %H:%M:%S')"
    echo "created on   : $(hostname -f 2>/dev/null || hostname) ($(. /etc/os-release && echo "$PRETTY_NAME"))"
    echo "created by   : $(id -un)"
    echo "DMS image    : ${DMS_IMAGE}"
    [[ $DO_FIPS -eq 1 && $ONLY_SIGS -eq 0 ]] && echo "FIPS image   : ${FIPS_IMAGE} (OpenSSL FIPS provider ${OPENSSL_FIPS_VERSION}, CMVP #${CMVP_CERT:-?})"
    echo
    [[ -f "$OUT/versions.txt" ]] && { echo "== component versions =="; cat "$OUT/versions.txt"; echo; }
    for f in "$OUT"/images/*.ids; do [[ -f "$f" ]] && cat "$f"; done
    echo
    echo "== contents =="
    (cd "$OUT" && find . -path ./.work -prune -o -type f ! -name SHA256SUMS ! -name MANIFEST.txt -print | sort \
       | while read -r p; do printf '%10s  %s\n' "$(du -h "$p" | cut -f1)" "${p#./}"; done)
    if ((${#WARNINGS[@]})); then echo; echo "== warnings =="; printf ' - %s\n' "${WARNINGS[@]}"; fi
  } > "$OUT/MANIFEST.txt"
  (cd "$OUT" && find . -path ./.work -prune -o -type f ! -name SHA256SUMS -print | sort | sed 's|^\./||' \
     | xargs -d '\n' sha256sum > SHA256SUMS)
  ok "MANIFEST.txt + SHA256SUMS"
}

make_tar() {
  local tarball="${OUT}.tar"
  log "creating ${tarball}"
  tar --exclude='.work' -cf "$tarball" -C "$(dirname "$OUT")" "$(basename "$OUT")"
  sha256sum "$tarball" > "${tarball}.sha256"
  ok "bundle: ${tarball} ($(du -h "$tarball" | cut -f1))"
  ok "sha256: $(cut -d' ' -f1 "${tarball}.sha256")"
}

# ============================================================================= main
REAL_HOME="$HOME"
log "DMS ${DMS_TAG} -> ${OUT}"

if [[ $ONLY_SIGS -eq 1 ]]; then
  [[ $DO_CLAMAV -eq 1 ]] && fetch_clamav
  [[ $DO_SA -eq 1 ]] && fetch_spamassassin
else
  pull_dms_image
  fetch_dms_source
  if [[ $DO_FIPS -eq 1 ]]; then
    select_fips_version
    fetch_openssl_source
    build_fips_image
  fi
  [[ $DO_CLAMAV -eq 1 ]] && fetch_clamav
  [[ $DO_SA -eq 1 ]] && fetch_spamassassin
  [[ $DO_RPMS -eq 1 ]] && fetch_rpms
  [[ $DO_TOOLS -eq 1 ]] && fetch_tools
  copy_deploy_kit
fi
write_manifest
[[ $DO_TAR -eq 1 ]] && make_tar
rm -rf "$WORK"

echo
ok "done."
if ((${#WARNINGS[@]})); then
  printf '%s[!] %d warning(s) - review MANIFEST.txt:%s\n' "$c_warn" "${#WARNINGS[@]}" "$c_off"
  printf '    - %s\n' "${WARNINGS[@]}"
fi
cat <<EOF

Enclave side (see setup-instructions.md):
  sha256sum -c $(basename "$OUT").tar.sha256 && tar -xf $(basename "$OUT").tar
  cd $(basename "$OUT") && sha256sum -c SHA256SUMS
  sudo podman load -i images/dms-fips-${DMS_TAG}.tar     # or images/dms-${DMS_TAG}.tar (Option A)
EOF
