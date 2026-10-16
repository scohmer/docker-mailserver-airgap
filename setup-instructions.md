# docker-mailserver: FIPS-Hardened, Air-Gapped Deployment Guide

Target host: **EL8** (RHEL / Rocky / Alma **8.10**), SELinux enforcing, FIPS mode, rootful **Podman 4.9**
(`container-tools:rhel8` module) with **podman-compose 1.0.6** (EPEL 8) and the **CNI** network backend
(the EL8 default). Docker Engine works too, but read §1.3 first.

> The staging machine on the connected side can be anything with Podman, including EL8, EL9 or EL10. The EL8 RPMs
> are built inside a Rocky 8.10 container (§2.0). The FIPS image was built and runtime-tested on an EL10 staging host.
> EL8 package installation and the compose translation were tested in Rocky 8.10 containers (§9).

Files in this repository (deployed to `/opt/dockermail`):

| File | Purpose |
|---|---|
| `docker-compose.yml` | Service definition (ports, volumes, capabilities, health check, logging) |
| `.env.example` | Every DMS v16 variable plus compose/host settings. Copy it to **`.env`** (gitignored) and run **chmod 600** (§3.8) |
| `README.md`, `.gitignore` | Repository overview; keeps `.env`, keys, certificates, generated DMS state and bundles out of git |
| `setup-instructions.md` | This guide |
| `fetch-offline-bundle.sh` | **Connected side:** downloads, verifies, builds and packages everything (§2) |
| `Dockerfile.fips` | Builds DMS + the validated OpenSSL FIPS provider (§4) |
| `docker-data/dms/fips/openssl.cnf` | System-wide OpenSSL policy, FIPS provider variant (§5.1) |
| `docker-data/dms/fips/openssl.cnf.policy-only` | Same policy without the FIPS provider, for Option A (§5.1) |
| `docker-data/dms/config/postfix-main.cf` | Postfix TLS/FIPS overrides (§5.2) |
| `docker-data/dms/config/dovecot.cf` | Dovecot **2.4** TLS/FIPS overrides (§5.3) |
| `docker-data/dms/config/user-patches.sh` | Internal CA trust, offline freshclam, provider logging (§5.4) |

You still have to **supply** these inside the enclave (§5.5):

```
docker-data/dms/certs/fullchain.pem   # server cert + intermediates (internal PKI)
docker-data/dms/certs/privkey.pem     # server private key
docker-data/dms/ca/*.crt              # internal root/intermediate CAs (PEM, .crt extension)
```
`mail-data/`, `mail-state/` and `mail-logs/` already exist and start out empty.

---

## 1. Read this first: what "FIPS" covers here

### 1.1 FIPS 140-2 vs 140-3
On **21 Sep 2026** every remaining FIPS 140-2 certificate moved to the CMVP *Historical*
list. Historical modules generally can't be used to claim compliance for new systems.
Ask your ISSM/assessor whether the requirement is really **FIPS 140-3** now (it
usually is). This guide uses 140-3 modules wherever there's a choice.

### 1.2 The host's FIPS mode does not cover the container
A container uses the **host kernel** but **its own userspace crypto libraries**. The DMS
image is built on **Debian** and links Postfix, Dovecot and OpenDKIM against Debian's
OpenSSL. Debian's OpenSSL is not CMVP-validated and ignores the host's
`/proc/sys/crypto/fips_enabled`. You have two options:

| | Option A: policy-only | Option B: validated provider (recommended) |
|---|---|---|
| Image | Upstream DMS image as-is | DMS image + OpenSSL **FIPS provider** built from a CMVP-validated source release (§4) |
| Algorithms | Restricted to FIPS-approved TLS suites and groups by config | Same restriction, **and** all OpenSSL crypto runs in a validated module; non-approved algorithms are unavailable |
| Compliance claim | "FIPS-approved algorithms only" (usually needs a POA&M / risk acceptance) | "Uses a FIPS 140-3 validated module, operating in its approved mode" |
| Effort | Low | Build one image on the connected side for each DMS upgrade |

### 1.3 Crypto outside the boundary (same for both options; document these in your SSP)
| Component | Crypto | Mitigation |
|---|---|---|
| Container runtime | **Podman on RHEL/Rocky 8** is built with Red Hat's Go toolchain, which routes crypto to the system OpenSSL in FIPS mode. **Docker Engine (moby)** uses native Go crypto, which is not validated. | Use Podman from the `container-tools:rhel8` module. |
| Dovecot password hashes (`ACCOUNT_PROVISIONER=FILE`) | `SHA512-CRYPT` via glibc, not OpenSSL | Use **LDAP/AD with `DOVECOT_AUTH_BIND=yes`** (§6.2), so passwords are verified by the directory and never hashed by DMS. |
| ClamAV, Amavis, SpamAssassin, Rspamd | MD5/SHA-1/BLAKE2 used for fingerprinting, not security | Non-security use. Note it in the SSP. ClamAV runs under a scoped non-FIPS OpenSSL config (§4.5). |
| Rspamd | Its own crypto library (libsodium) for fuzzy hashes and controller | This is one reason the classic stack is the default here (§7). |
| Host OS crypto | RHEL 8's kernel/OpenSSL/libgcrypt/GnuTLS/NSS modules are CMVP-certified. Several RHEL 8 certificates were **140-2 and are now Historical**. Community Rocky/Alma 8 aren't certified under their own names (CIQ sells a validated Rocky build). | Search CMVP for "Red Hat Enterprise Linux 8" and confirm an *Active* 140-3 certificate covers your 8.x minor. Confirm which host OS your ATO allows. |

### 1.4 Host FIPS mode (EL8)
EL8 can switch FIPS on after installation, but Red Hat recommends installing with FIPS enabled
(kernel arg `fips=1`). Keys and certificates generated before the switch weren't created by a FIPS module, so regenerate host SSH keys afterwards.

```bash
fips-mode-setup --check                # "FIPS mode is enabled."
cat /proc/sys/crypto/fips_enabled      # must print 1
update-crypto-policies --show          # FIPS (or FIPS:OSPP on some STIG baselines)

# If it is not enabled:
sudo fips-mode-setup --enable && sudo reboot
```
`FIPS:OSPP` is stricter than `FIPS` on the host side, but it doesn't affect the container, whose policy comes from
`openssl.cnf` (§5.1). Host-side tools such as `openssl s_client` and `curl` follow the host policy.

---

## 2. Connected side: what to download and bring across

Use a staging machine with internet access and rootful or rootless Podman (≥ 4.4). Its OS doesn't matter:
the EL8 RPMs are resolved inside an EL8.10 container. Hash everything (`sha256sum`), record the hashes on
the transfer form, and scan the media according to your cross-domain procedure.

### 2.0 Automated: `fetch-offline-bundle.sh`
Steps 2.1–2.5 and §4 are scripted. On the connected staging host, run this from the `/opt/dockermail` checkout:

```bash
./fetch-offline-bundle.sh                       # everything: DMS 16.0.1, FIPS image, ClamAV, RPMs, tools
./fetch-offline-bundle.sh --spamassassin        # also SpamAssassin rules
./fetch-offline-bundle.sh --no-fips             # Option A (upstream image only)
./fetch-offline-bundle.sh --only-signatures     # recurring ClamAV (+SA) refresh only
./fetch-offline-bundle.sh -t 16.0.2             # a newer DMS tag
./fetch-offline-bundle.sh --help
```

The script does the following:
1. Pulls and saves the pinned DMS image, then records the versions of the Debian base, OpenSSL, Postfix, Dovecot and ClamAV (`versions.txt`).
2. Downloads the DMS source at the same tag (offline docs) and diffs its `mailserver.env` against `.env` (`env-diff.txt`).
3. Chooses the FIPS provider version for the image's Debian release, downloads the OpenSSL source, checks its **SHA-256 and GPG signature** (using a separate keyring), and downloads the CMVP Security Policy PDF.
4. Builds `localhost/docker-mailserver-fips:<tag>` with `Dockerfile.fips`, then checks it: the provider must be active, SHA-256 must work, MD5 must be blocked, and ClamAV hashing is tested.
5. Collects ClamAV signatures with `cvdupdate`, using the newest Python available (EL8's default `python3` is 3.6), and SpamAssassin rules (optional).
6. **Builds an EL8.10 offline repo inside a `rockylinux:8.10` container** (§2.6): the requested packages with all
   dependencies, EPEL 8 packages (`podman-compose`, `swaks`), *sibling* packages, AppStream **module metadata**,
   the GPG keys, and an `install-offline.sh` for the enclave.
7. Downloads testssl.sh (and the docker-compose binary if `COMPOSE_VERSION` is set), then copies the deployment kit, leaving out certificates and mail data.
8. Writes `MANIFEST.txt` (versions, image IDs, warnings) and `SHA256SUMS`, then creates `offline-bundle-<tag>-<date>.tar` and its `.sha256`.

GPG: the script trusts only the primary-key fingerprints that OpenSSL publishes in `doc/fingerprints.txt`, taken from the
release tag and from `master`. It imports keys from `openssl-library.org/source/pubkeys.asc`, falling back to
`keyserver.ubuntu.com`, and **fails** unless the signature is good *and* the signer is in that list. OpenSSL 3.1.2 is
signed by the "OpenSSL OMC" key `EFC0 A467 D613 CB83 C7ED 6D30 D894 E2CE 8B3D 79F5`. To pin signers yourself, set
`OPENSSL_TRUSTED_FPRS="<fpr> ..."`. Use `--skip-gpg` only with ISSM approval.

On the enclave side:
```bash
sha256sum -c offline-bundle-16.0.1-*.tar.sha256 && tar -xf offline-bundle-16.0.1-*.tar
cd offline-bundle-16.0.1-*/ && sha256sum -c SHA256SUMS && less MANIFEST.txt
sudo ./rpms/install-offline.sh                 # EL8 host packages (§2.6), if your mirror lacks them
sudo podman load -i images/dms-fips-16.0.1.tar
sudo cp -a deploy/. /opt/dockermail/
```

The rest of §2 describes what the script does, for manual use or review.

### 2.1 Download checklist

| # | Item | Where it comes from | How to fetch | Needed for |
|---|---|---|---|---|
| 1 | **DMS container image**, pinned tag (e.g. `16.0.1`, or the newest stable tag you've vetted) | `ghcr.io/docker-mailserver/docker-mailserver` | §2.2 | Always |
| 2 | **DMS source tarball at the same tag** (docs, reference `mailserver.env`, `CHANGELOG.md`) | `https://github.com/docker-mailserver/docker-mailserver/archive/refs/tags/v<TAG>.tar.gz` | `curl -LO` | Always (offline docs + variable diff) |
| 3 | **FIPS-provider DMS image** (built on the connected side) | Built from #1 + #4 | §4 | Option B |
| 4 | **OpenSSL source of a validated FIPS provider** + `.sha256` + `.asc`, and the OpenSSL OMC PGP key | `https://github.com/openssl/openssl/releases/tag/openssl-<ver>` | `curl -LO` and `gpg --verify` | Option B (build only; doesn't need to cross) |
| 5 | **CMVP certificate + Security Policy PDF** for that provider | `https://csrc.nist.gov/projects/cryptographic-module-validation-program` (search "OpenSSL") | Browser | ATO package |
| 6 | **ClamAV signatures** `main.cvd`, `daily.cvd`, `bytecode.cvd` (plus `*.cvd.sign` if your cvdupdate/ClamAV version produces them) | ClamAV CDN, via Cisco Talos `cvdupdate` | §2.3 | `ENABLE_CLAMAV=1` (re-fetch on a recurring schedule) |
| 7 | **SpamAssassin rules** tarball | `sa-update` run inside the same DMS image | §2.4 | Only if `ENABLE_SPAMASSASSIN=1` |
| 8 | **EL8.10 host RPMs**: `podman`, `podman-docker`, `containernetworking-plugins`, `container-selinux` (`container-tools:rhel8` module), `firewalld`, `chrony`, `openssl`, `bind-utils`, `nmap`, `nmap-ncat`; from EPEL 8: `podman-compose` (1.0.6), `swaks` | EL8 BaseOS + AppStream, EPEL 8 | §2.6 (scripted) | Host prep |
| 9 | *(Alternative compose provider)* `docker-compose-linux-x86_64` v2 binary + `.sha256` | `https://github.com/docker/compose/releases` | `curl -LO` | Only if you don't want `podman-compose` |
| 10 | *(Optional)* `testssl.sh` release tarball | `https://github.com/testssl/testssl.sh/releases` | `curl -LO` | TLS verification (§9) |

From **inside** the enclave (not the internet), you also need:

- A server certificate from your internal PKI for `MAIL_FQDN` (SAN must include it), using
  RSA ≥ 3072 or ECDSA P-384, with the full intermediate chain
- The internal root and intermediate CA certificates (PEM)
- DNS records (§6.4) and internal NTP and DNS server addresses
- If using LDAP: a read-only bind service account

### 2.2 Export the image (connected side)

```bash
TAG=16.0.1   # pin it; never use latest/edge
podman pull ghcr.io/docker-mailserver/docker-mailserver:${TAG}
podman image inspect --format '{{.Digest}}  {{.Id}}' \
  ghcr.io/docker-mailserver/docker-mailserver:${TAG} | tee dms-${TAG}.ids
podman save --format docker-archive -o dms-${TAG}.tar \
  ghcr.io/docker-mailserver/docker-mailserver:${TAG}
sha256sum dms-${TAG}.tar > dms-${TAG}.tar.sha256

# Record which Debian release and OpenSSL the image uses (determines §4):
podman run --rm --entrypoint sh ghcr.io/docker-mailserver/docker-mailserver:${TAG} \
  -c 'cat /etc/debian_version; openssl version; postconf -d mail_version; dovecot --version; clamscan --version'
```

### 2.3 ClamAV signatures (connected side)

ClamAV's CDN blocks scripted downloads that don't behave like freshclam. Use Cisco Talos's `cvdupdate`:

```bash
python3.11 -m venv ~/cvd && ~/cvd/bin/pip install cvdupdate   # EL8: use python3.11/3.12, not the 3.6 default
~/cvd/bin/cvd config set --dbdir "$PWD/clamav-db"
~/cvd/bin/cvd update            # do not run more than once a day (rate limits)
tar -czf clamav-db-$(date +%F).tgz -C clamav-db .
sha256sum clamav-db-*.tgz > clamav-db.sha256
```

### 2.4 SpamAssassin rules (connected side, only if enabled)

```bash
mkdir -p sa-out
podman run --rm --entrypoint bash -v "$PWD/sa-out:/out:Z" \
  ghcr.io/docker-mailserver/docker-mailserver:${TAG} \
  -c 'sa-update -v; tar -czf /out/sa-rules-$(date +%F).tgz -C /var/lib/spamassassin .'
```

### 2.5 Reference `mailserver.env` diff
DMS adds, renames and deprecates variables between releases. Extract item #2 and diff it against the shipped `.env`:

```bash
tar -xzf v${TAG}.tar.gz
diff <(grep -oE '^[A-Z0-9_]+=' docker-mailserver-${TAG}/mailserver.env | sort -u) \
     <(grep -oE '^[A-Z0-9_]+=' /opt/dockermail/.env.example | sort -u)
```
Lines starting with `<` are variables your release has and the `.env` lacks; add them.
Lines starting with `>` are either compose-only variables (section 0 of `.env`) or obsolete; remove obsolete ones.

### 2.6 EL8 host RPMs: why the repo is built this way
Plain `dnf download --alldeps` plus `createrepo_c` **doesn't work offline on EL8**. Both failures below were reproduced in Rocky 8.10:
1. **Modular filtering.** `podman`, `runc` and `container-selinux` come from the `container-tools:rhel8` module. A repo
   without module metadata hides them, so dnf reports "package podman is not installed". The script copies AppStream's
   `modules.yaml` into the repo with `modifyrepo_c --mdtype=modules`.
2. **Sibling packages.** A newer dependency, for example `rpm-libs`, requires matching versions of packages already on
   the target that come from the same source RPM, for example `python3-rpm` and `rpm-build-libs`. Without them the
   transaction fails ("cannot install both rpm-libs-…-32 and …-31"). The script adds every package that is installed on
   the target **and** shares a source RPM with something downloaded. By default "installed on the target" means a
   stock `rockylinux:8.10` container. For an exact match, bring the enclave host's package list across (with your
   cross-domain approval) and pass it in:
   ```bash
   # enclave host:  rpm -qa --qf '%{NAME}\n' > target-rpm-qa.txt
   TARGET_RPM_QA=./target-rpm-qa.txt ./fetch-offline-bundle.sh
   ```
3. Installing every downloaded file with `dnf install ./*.rpm` **also fails**, because `--alldeps` pulls in alternative
   providers that conflict with dnf itself. Use `rpms/install-offline.sh`, which installs only the named packages from
   the local repo with `gpgcheck=1`:
   ```bash
   sudo ./rpms/install-offline.sh
   # = rpm --import gpg-keys/RPM-GPG-KEY-*; dnf --disablerepo='*' --repofrompath=offline,<dir> --setopt=offline.gpgcheck=1 install <pkgs>
   ```

**RHEL 8 targets:** the default builder is Rocky Linux 8.10. To get genuine RHEL RPMs, run the script on a
**subscribed RHEL host** with `RPM_BUILDER_IMAGE=registry.access.redhat.com/ubi8/ubi:8.10`. UBI containers inherit the
host's entitlement and see the full RHEL repos. Better still, if the enclave already has a Satellite or reposync
mirror of BaseOS/AppStream, install from it and use the bundle only for the EPEL packages.

---

## 3. Enclave side: EL8 host preparation

```bash
# 3.1 Packages: from the enclave's EL8 mirror, or from the bundle (§2.6)
sudo dnf module enable -y container-tools:rhel8            # default stream; harmless if already enabled
sudo dnf install podman podman-docker podman-compose containernetworking-plugins \
                 container-selinux firewalld chrony openssl bind-utils
#   or: sudo ./rpms/install-offline.sh
podman --version; podman-compose version                    # expect 4.9.x / 1.0.6
sudo touch /etc/containers/nodocker                         # silence the docker-shim banner

# 3.2 FIPS check (see §1.4)
fips-mode-setup --check; update-crypto-policies --show

# 3.3 Time: point chrony at internal NTP (accurate time matters for TLS, DKIM and logs)
sudoedit /etc/chrony.conf   # server ntp1.example.internal iburst
sudo systemctl enable --now chronyd

# 3.4 Host MTA must not hold port 25 (EL8 STIG builds often ship postfix)
sudo systemctl disable --now postfix 2>/dev/null || true

# 3.5 Firewall
sudo firewall-cmd --permanent --add-service=smtp --add-service=smtps \
                  --add-service=smtp-submission --add-service=imaps
sudo firewall-cmd --reload

# 3.6 Graceful shutdown: podman-compose 1.0.6 IGNORES stop_grace_period, so set it
#     host-wide (Podman's default of 10s can cut off Postfix/Dovecot mid-write)
sudo mkdir -p /etc/containers/containers.conf.d
printf '[engine]\nstop_timeout = 60\n' | sudo tee /etc/containers/containers.conf.d/50-mailserver.conf

# 3.7 Start containers at boot (podman-restart.service ships with Podman 4.9; honours restart: always)
sudo systemctl enable podman-restart.service

# 3.8 Directories
cd /opt/dockermail
sudo mkdir -p docker-data/dms/{config,fips,certs,ca,mail-data,mail-state,mail-logs}
sudo cp -n .env.example .env && sudo chmod 600 .env    # .env is gitignored; never commit it
sudo chmod 700 docker-data/dms/certs
```

**EL8-specific notes**
- **Network backend:** EL8's `/usr/share/containers/containers.conf` sets `network_backend = "cni"`. The compose
  network becomes a CNI bridge, configured in `/etc/cni/net.d/mailserver_mailnet.conflist`. You don't need netavark or
  aardvark-dns. Don't switch backends while containers exist (`podman system reset` would be required).
- **Kernel 4.18 vs Debian 13 userspace:** glibc in the image calls newer syscalls such as `clone3` and `faccessat2`.
  EL8.10's seccomp profile returns `ENOSYS` (`defaultErrnoRet: 38`) for unknown syscalls, so glibc falls back
  cleanly. On hosts older than 8.10 with an older `containers-common`, run `sudo dnf update containers-common` first.
- **cgroups v1** (EL8 default) is fine for rootful Podman, including health checks, which run on systemd timers.
- **Fail2Ban** inside the container uses nftables. Make sure the host can load the modules:
  `echo nf_tables | sudo tee /etc/modules-load.d/dms-nftables.conf && sudo modprobe nf_tables`.
- **fapolicyd** (enabled by the RHEL 8 STIG) can deny execution of files in container storage. If the container
  won't start, check `sudo ausearch -m fanotify -ts recent`, then add a trust rule for
  `/var/lib/containers/storage/` per your site policy.
- **STIG mount options:** `/var/lib/containers` must **not** be mounted `noexec`.
- Use `podman-compose …` directly. `podman compose` on 4.9 just calls it anyway.

Suggested extra hardening:
- Put `/opt/dockermail/docker-data` on its own LUKS-encrypted LV, mounted `nodev,nosuid`.
- Add an auditd watch: `-w /opt/dockermail -p wa -k dockermail`.
- Forward journald (the container logs there, `tag=mailserver`) to your SIEM.

**Run all `podman`/`podman-compose` commands as root (`sudo`).** Rootless Podman can't bind
ports < 1024 or give Fail2Ban `NET_ADMIN` without extra sysctls.

### 3.9 Load the image
If you used the bundle script, `podman load` the tarballs under `images/` and check them against `MANIFEST.txt`.

```bash
sha256sum -c dms-${TAG}.tar.sha256
sudo podman load -i dms-${TAG}.tar                # Option A
sudo podman load -i dms-fips-${TAG}.tar           # Option B (from §4)
sudo podman image inspect --format '{{.Id}}' <image>   # compare with dms-${TAG}.ids
```
Set `DMS_IMAGE` in `.env` to the exact name that `podman images` shows.

---

## 4. Option B: build the FIPS-provider image (connected side)

### 4.1 Pick the provider version that matches the image's OpenSSL
A validated provider only runs on an OpenSSL `libcrypto` of the **same or newer** version.
Use the `debian_version` and `openssl version` you recorded in §2.2:

| DMS base | Image libcrypto | Validated provider to build | CMVP status (verify on the NIST site) |
|---|---|---|---|
| Debian 13 (trixie) | 3.5.x | **3.1.2** (cert #4985, FIPS 140-3); or a 3.5.x provider if its 140-3 certificate has been issued | Active |
| Debian 12 (bookworm) | 3.0.x | 3.0.8 / 3.0.9 (cert #4282, **FIPS 140-2**) | **Historical since 21 Sep 2026** |

**DMS v16.x (the default here) is based on Debian 13**, so the 140-3 provider 3.1.2 applies.
If you're pinned to DMS v15.x (bookworm), the only provider that will run is a historical 140-2
module. In that case, either use a newer DMS release on trixie or get your assessor to
accept the historical module in writing.

Always check the certificate's **Security Policy** for the exact version string and build
instructions, and follow them; they override the generic steps below.

### 4.2 `Dockerfile.fips`
The file is in `/opt/dockermail/Dockerfile.fips`. It has two stages:
1. **fips-build** (`debian:<same release>-slim`): `./Configure enable-fips && make && make install_fips`
   builds `fips.so`, and `fipsmodule.cnf` contains the module's integrity MAC.
2. **final** (`ghcr.io/docker-mailserver/docker-mailserver:<tag>`): copies `fips.so` into
   `/usr/lib/x86_64-linux-gnu/ossl-modules/` and `fipsmodule.cnf` to `/etc/ssl/`. The build
   **fails** unless the provider passes its self-tests and loads, SHA-256 works, and MD5 is refused.

If the Security Policy for your certificate prescribes different build steps, change the
`fips-build` stage to follow it.

### 4.3 Build and export

```bash
curl -LO https://github.com/openssl/openssl/releases/download/openssl-3.1.2/openssl-3.1.2.tar.gz{,.sha256,.asc}
sha256sum openssl-3.1.2.tar.gz; cat openssl-3.1.2.tar.gz.sha256
gpg --verify openssl-3.1.2.tar.gz.asc openssl-3.1.2.tar.gz   # import OpenSSL OMC keys first

podman build -f Dockerfile.fips --build-arg DMS_TAG=${TAG} \
  --build-arg DEBIAN_TAG=13-slim --build-arg OPENSSL_FIPS_VERSION=3.1.2 \
  -t localhost/docker-mailserver-fips:${TAG} .
podman save --format docker-archive -o dms-fips-${TAG}.tar localhost/docker-mailserver-fips:${TAG}
sha256sum dms-fips-${TAG}.tar > dms-fips-${TAG}.tar.sha256
```
Keep `Dockerfile.fips`, the tarball hashes, the GPG output and the Security Policy PDF with your ATO evidence.

### 4.4 How the provider is activated
`fips/openssl.cnf` (§5.1, Variant B) is bind-mounted over `/etc/ssl/openssl.cnf`. It loads
only the `fips` and `base` providers and sets `default_properties = fips=yes`. Postfix,
Dovecot, OpenDKIM and every other program using Debian's libssl then get crypto only from
the validated module. `config_diagnostics = 1` makes a broken configuration **fail closed**,
so services refuse to start instead of silently running without FIPS.

### 4.5 ClamAV: scoped non-FIPS exception (built in)
DMS 16.0.1 ships **ClamAV 1.4.3**. It fetches MD5/SHA-1 for *non-security* file fingerprinting and CVD signature
checks, so under the FIPS provider it fails with `ERROR: hashsig: Can't generate hash`. This was verified, and loading the
`default` provider alongside does **not** help.

`Dockerfile.fips` therefore wraps **only** `clamd`, `clamscan`, `freshclam` and `sigtool`. The real binaries keep their
names in `/usr/lib/clamav-nonfips/`, and the wrapper sets `OPENSSL_CONF=/etc/ssl/openssl-clamav-nonfips.cnf` (default
provider). All other processes (Postfix, Dovecot, OpenDKIM, Amavis) still use the FIPS-only `/etc/ssl/openssl.cnf`.
Document this in the SSP as "non-cryptographic use of MD5/SHA-1 by the AV engine; no security function relies on it".

If your assessor won't accept the exception, build with `--build-arg CLAMAV_NONFIPS_EXCEPTION=0`, set
`ENABLE_CLAMAV=0`, and scan for viruses on an upstream gateway. Remove the exception when DMS ships a ClamAV release
that supports FIPS mode.

---

## 5. Custom configuration files (already created)

### 5.1 `docker-data/dms/fips/openssl.cnf`
This file is bind-mounted over `/etc/ssl/openssl.cnf`, so it applies to every OpenSSL user in the container.
- **`openssl.cnf`** (Variant B, the default) includes `/etc/ssl/fipsmodule.cnf`. It loads only the `fips` and `base`
  providers, sets `default_properties = fips=yes`, and sets `config_diagnostics = 1` so errors fail closed. It also
  sets a TLS system default: TLS ≥ 1.2, ECDHE+AES-GCM only, TLS 1.3 `AES_256_GCM`/`AES_128_GCM` only, groups P-384/P-256,
  approved signature algorithms, server cipher preference, and no renegotiation or compression.
  A commented `default` provider block is there for the ClamAV case (§4.5).
- **`openssl.cnf.policy-only`** (Variant A) has the same TLS policy without the provider. For Option A, run
  `cp openssl.cnf.policy-only openssl.cnf`.

> Variant B on the upstream image will stop every TLS service from starting, because
> `fipsmodule.cnf` doesn't exist there. Match the variant to the image.

### 5.2 `docker-data/dms/config/postfix-main.cf`
DMS appends this file to `main.cf` and normalises it with `postconf -n`, so these values override the defaults.
- TLS ≥ 1.2 for `smtpd` and `smtp`
- The `high` cipher grade, set to ECDHE + AES-GCM only, with ChaCha20, CBC/SHA1, CAMELLIA/ARIA and other suites excluded
- Curves `secp384r1 prime256v1`
- SHA-256 fingerprints
- No compression or renegotiation
- `smtpd_tls_auth_only`, `disable_vrfy_command`, and a generic banner

`smtp_tls_security_level = may` is left at the default. Raise it to `encrypt`/`secure`
once every internal peer MTA has a PKI certificate.

### 5.3 `docker-data/dms/config/dovecot.cf`
DMS copies this file to `/etc/dovecot/local.conf`, which loads last and overrides the ChaCha20-inclusive
`TLS_LEVEL` defaults. It uses **Dovecot 2.4 syntax**: DMS v16 moved from Dovecot 2.3 to 2.4, and the v16 changelog says
2.3-syntax files won't load. Settings: `ssl = required`, FIPS cipher list and suites, `ssl_curve_list = P-384:P-256`,
`ssl_server_prefer_ciphers = server`, `ssl_options = no_ticket`, `auth_allow_cleartext = no`,
a generic greeting, and the **port 143 listener disabled** (`port = 0`).

### 5.4 `docker-data/dms/config/user-patches.sh`
DMS runs this script at the end of container setup, before services start. It:
1. Runs `update-ca-certificates` for anything in `ca/*.crt`, for LDAPS, the relay host and `smtp_tls_CAfile`.
2. Rewrites `freshclam.conf` so it never contacts the ClamAV CDN. It uses `CLAMAV_PRIVATE_MIRROR` if set; otherwise it
   points at loopback and checks once a day.
3. Logs `openssl version` and the active providers. This gives audit evidence in `podman logs`.

### 5.5 Certificates and CAs

```bash
# Server cert: leaf first, then intermediates. Key: RSA>=3072 or ECDSA P-384.
sudo install -m 644 server-fullchain.pem docker-data/dms/certs/fullchain.pem
sudo install -m 600 server-key.pem       docker-data/dms/certs/privkey.pem
# Internal CAs: one cert per file, PEM, extension MUST be .crt
sudo install -m 644 Org-Root-CA.pem docker-data/dms/ca/org-root-ca.crt
sudo install -m 644 Org-Issuing-CA.pem docker-data/dms/ca/org-issuing-ca.crt

openssl x509 -in docker-data/dms/certs/fullchain.pem -noout -subject -ext subjectAltName -enddate
```
The key must be unencrypted (DMS can't prompt for a passphrase). Protect it with the
directory permissions, the encrypted LV, and SELinux `:Z` labeling.
If you have an HSM-backed requirement for the private key, DMS doesn't support it.

---

## 6. Configure `.env`, then do the first start

### 6.1 Values you must change in `.env`
`.env` is your copy of `.env.example` (§3.8). It's gitignored because it will hold credentials and site details. When you
upgrade, merge new variables from `.env.example` into it.

`DMS_IMAGE`, `MAIL_FQDN`, `MAIL_DOMAIN`, `MAIL_BIND_IP`, `DNS_SERVER_1/2`,
`MAIL_NET_SUBNET` (must not overlap your networks), `POSTMASTER_ADDRESS`, and, if you use
them, `DEFAULT_RELAY_HOST`, the `LDAP_*` variables, and `CLAMAV_PRIVATE_MIRROR`.
The hardened values already set are `ENABLE_UPDATE_CHECK=0`, `ENABLE_DNSBL=0`,
`ENABLE_MTA_STS=0`, `ENABLE_SPAMASSASSIN_KAM=0`, `PERMIT_DOCKER=none`,
`SPOOF_PROTECTION=1`, `ENABLE_POP3=0`, `TLS_LEVEL=modern`, and `SSL_TYPE=manual`.
Each of these either stops a call to the internet or narrows exposure.

Write any `$` in passwords as `$$`.

### 6.2 Accounts: LDAP/AD (recommended) or FILE
- **LDAP:** set `ACCOUNT_PROVISIONER=LDAP`, fill in the `LDAP_*` variables, use `ldaps://`, and
  set `DOVECOT_AUTH_BIND=yes`. Put the directory's CA in `ca/`.
- **FILE:** leave `ACCOUNT_PROVISIONER=FILE` and create accounts after startup (§6.3).
  DMS waits about 120 s for the first account before Dovecot comes up.

### 6.3 Start

```bash
cd /opt/dockermail
sudo podman-compose config > /dev/null && echo OK      # validates interpolation
sudo podman-compose up -d
sudo podman logs -f mailserver                           # watch for [user-patches] and errors

# FILE provisioner: create accounts and aliases
sudo podman exec -it mailserver setup email add admin@example.internal
sudo podman exec -it mailserver setup alias add postmaster@example.internal admin@example.internal
sudo podman exec -it mailserver setup alias add abuse@example.internal admin@example.internal

# DKIM key (RSA 2048; 4096-bit keys often exceed DNS TXT limits)
sudo podman exec -it mailserver setup config dkim keysize 2048 domain example.internal
cat docker-data/dms/config/opendkim/keys/example.internal/mail.txt   # publish in DNS (6.4)
sudo podman restart mailserver
```

### 6.4 Internal DNS records

| Type | Name | Value |
|---|---|---|
| A | `mail.example.internal` | `10.0.0.25` |
| PTR | `25.0.0.10.in-addr.arpa` | `mail.example.internal.` |
| MX | `example.internal` | `10 mail.example.internal.` |
| TXT | `example.internal` | `v=spf1 mx -all` |
| TXT | `mail._domainkey.example.internal` | *(contents of `mail.txt`)* |
| TXT | `_dmarc.example.internal` | `v=DMARC1; p=reject; adkim=s; aspf=s` |

---

## 7. (Alternative) Rspamd instead of the classic stack
The classic stack (OpenDKIM, OpenDMARC, policyd-spf, Amavis, ClamAV) is the default here
because more of its crypto goes through OpenSSL and it makes fewer internet calls. To use
Rspamd instead, set `ENABLE_RSPAMD=1`, `ENABLE_RSPAMD_REDIS=1`, `ENABLE_OPENDKIM=0`,
`ENABLE_OPENDMARC=0`, `ENABLE_POLICYD_SPF=0`, `ENABLE_AMAVIS=0`, and
`ENABLE_SPAMASSASSIN=0`. Then create `config/rspamd/custom-commands.conf` to switch off
the modules that call the internet:

```
disable-module fuzzy_check
disable-module rbl
disable-module asn
disable-module phishing
disable-module url_redirector
```
After startup, run `grep -iE 'maps.rspamd.com|http' docker-data/dms/mail-logs/rspamd.log` and
disable any other module still trying to fetch remote maps. Use the offline DMS docs (§2.1 #2)
for DKIM signing with Rspamd.

---

## 8. Offline maintenance

### 8.1 ClamAV signatures (recurring, e.g. weekly)
DMS keeps ClamAV's database in `mail-state/lib-clamav`.

```bash
sha256sum -c clamav-db.sha256
mkdir -p /tmp/cvd && tar -xzf clamav-db-*.tgz -C /tmp/cvd
# Use cp (not mv) so files inherit the directory's SELinux container label
sudo cp /tmp/cvd/*.cvd* docker-data/dms/mail-state/lib-clamav/
sudo podman exec mailserver chown -R clamav:clamav /var/lib/clamav/
sudo podman exec mailserver supervisorctl restart clamav   # or: sudo podman restart mailserver
```
To serve updates instead: put the `.cvd` files on any internal HTTP server and set
`CLAMAV_PRIVATE_MIRROR=http://mirror.example.internal/clamav`. If Python is available
there, `cvd serve` can do this.

### 8.2 SpamAssassin rules (if enabled)
```bash
sudo tar -xzf sa-rules-*.tgz -C docker-data/dms/mail-state/lib-spamassassin/
sudo podman exec mailserver chown -R amavis:amavis /var/lib/spamassassin/  # check owner first with ls -ln
sudo podman exec mailserver supervisorctl restart amavis
```

### 8.3 Upgrading DMS
1. On the connected side, pull the new tag, read `CHANGELOG.md` for breaking changes and
   variable renames, redo §2.5, and rebuild Option B (§4) if you use it.
2. Transfer, verify the hashes, and run `podman load`.
3. Back up (§8.4), update `DMS_IMAGE`, run `sudo podman-compose down && sudo podman-compose up -d`, then verify (§9).
   `down` then `up` makes sure the container is recreated from the new image.

### 8.4 Backup
Back up `docker-data/dms/{config,mail-data,mail-state}`, `.env`, and `certs/`. The logs
are optional. For a consistent copy, stop the container briefly or snapshot the LV. Encrypt
backups with a FIPS-mode tool, such as `gpg`/`openssl` on the FIPS-enabled host.

---

## 9. Verification checklist

**Tested so far (16 Oct 2026):**
- *Container runtime, on an EL10 staging host (Podman 5.8):* `localhost/docker-mailserver-fips:16.0.1` with these exact config files.
  The provider was active and MD5 blocked. Ports 993, 465, 587 and 25 negotiated TLS 1.3 with `TLS_AES_256_GCM_SHA384`. TLS 1.1, ChaCha20 (TLS 1.2
  and 1.3), X25519 and CBC were rejected. Port 143 was closed, plaintext AUTH on 587 was refused, and EICAR was blocked by ClamAV.
- *EL8, in Rocky 8.10 containers:* the offline repo installed Podman 4.9.4 and podman-compose 1.0.6 with all repos
  disabled and `gpgcheck=1`. `podman-compose config` and `--dry-run up` translated every compose key except
  `stop_grace_period` (handled in §3.6). The seccomp profile returns ENOSYS.
- **Not yet tested:** a full run on a physical or virtual EL8 host with its 4.18 kernel. Run this checklist there before go-live.

Run the negative TLS tests from a **non-FIPS client**. A FIPS-mode host's own `openssl`
refuses ChaCha20 or TLS 1.1 on the client side, which looks like a server-side pass.

```bash
H=mail.example.internal
# Host
cat /proc/sys/crypto/fips_enabled                                   # 1
getenforce                                                          # Enforcing

# Container: Option B only
sudo podman exec mailserver openssl list -providers                 # fips (active), base
sudo podman exec mailserver openssl md5 /etc/hostname               # MUST fail
sudo podman exec mailserver openssl sha256 /etc/hostname            # works

# Positive TLS
openssl s_client -connect $H:993 -brief </dev/null                  # TLSv1.3, AES-GCM
openssl s_client -connect $H:465 -brief </dev/null
openssl s_client -starttls smtp -connect $H:587 -brief </dev/null
openssl s_client -starttls smtp -connect $H:25  -brief </dev/null

# Negative TLS: each MUST fail
openssl s_client -connect $H:993 -tls1_1 </dev/null
openssl s_client -connect $H:993 -tls1_2 -cipher ECDHE-RSA-CHACHA20-POLY1305 </dev/null
openssl s_client -connect $H:993 -tls1_3 -ciphersuites TLS_CHACHA20_POLY1305_SHA256 </dev/null
openssl s_client -connect $H:993 -groups X25519 </dev/null
nc -zv $H 143; nc -zv $H 110                                         # closed

# Full cipher enumeration
nmap --script ssl-enum-ciphers -p 25,465,587,993 $H                  # or ./testssl.sh $H:993

# Mail flow, auth, DKIM, AV
swaks --server $H:587 --tls --auth LOGIN --auth-user admin@example.internal \
      --from admin@example.internal --to admin@example.internal
sudo podman exec mailserver opendkim-testkey -d example.internal -s mail -vvv
# EICAR test (type the 68-byte EICAR string; nothing to download) -> mail must be quarantined
sudo podman exec mailserver tail -n 50 /var/log/mail/mail.log

# Nothing tries to reach the internet
sudo podman exec mailserver grep -riE 'github|clamav.net|spamhaus|rspamd.com' /var/log/mail/ | tail
```

---

## 10. Summary of deviations from DMS defaults (for the SSP)

| Area | Default | Hardened |
|---|---|---|
| Update check | on (GitHub) | `ENABLE_UPDATE_CHECK=0` |
| TLS | `intermediate`, OpenSSL defaults | TLS 1.2/1.3, ECDHE + AES-GCM only, P-384/P-256 groups, no ChaCha20/CBC/DHE/compression/renegotiation |
| Crypto module | Debian OpenSSL | OpenSSL FIPS provider 3.1.2 (CMVP #4985, 140-3), `fips=yes` (Option B); ClamAV-only exception (§4.5) |
| Certificates | none / Let's Encrypt | Internal PKI, `SSL_TYPE=manual` |
| Plaintext IMAP 143 / POP3 | enabled | Disabled (`port = 0`, `ENABLE_POP3=0`, not published) |
| Unauthenticated relay | `PERMIT_DOCKER=none` | unchanged; `SPOOF_PROTECTION=1` added |
| DNSBL / MTA-STS / KAM | various | all off (internet-dependent) |
| Signature updates | Internet (freshclam, sa-update) | Sneakernet / internal mirror |
| Brute force | Fail2Ban off | Fail2Ban on |
| Logging | json-file | journald → SIEM; 90 rotations inside the container |
| Runtime | Docker | EL8 rootful Podman 4.9 (FIPS-built Go), CNI, podman-compose 1.0.6, SELinux `:Z`, stop_timeout 60 s |
| Banners | software names | `ESMTP`, `Mail server ready.` |
