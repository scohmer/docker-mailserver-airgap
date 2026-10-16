# docker-mailserver-airgap

Deployment kit for [docker-mailserver](https://github.com/docker-mailserver/docker-mailserver) (DMS) **v16** in a
**FIPS 140-3-oriented, security-hardened, air-gapped** environment on **EL8** (RHEL / Rocky / Alma 8.10) with rootful
Podman 4.9 and podman-compose.

- **Validated crypto in the container.** An optional image layers the OpenSSL **FIPS provider 3.1.2** (CMVP #4985),
  built from GPG-verified source, onto DMS. Postfix, Dovecot and OpenDKIM run with `fips=yes`, and the build fails if
  MD5 isn't blocked. ClamAV, which uses hashes for non-security purposes, runs under a documented, scoped exception.
- **FIPS-approved TLS only.** TLS 1.2/1.3 with ECDHE + AES-GCM and P-384/P-256 is enforced in OpenSSL, Postfix and Dovecot.
  ChaCha20, X25519, CBC and TLS ≤ 1.1 are rejected, plaintext IMAP (143) is disabled, and cleartext AUTH is refused.
- **Nothing calls the internet.** The update check, DNSBLs, MTA-STS and KAM rules are off, and ClamAV and
  SpamAssassin updates come in through the transfer bundle or an internal mirror.
- **One-shot transfer bundle.** `fetch-offline-bundle.sh` runs on the connected side. It collects the images, the FIPS
  build, ClamAV signatures, an **EL8 offline RPM repo** (module-aware, with GPG keys and an installer), docs, a manifest
  and SHA-256 sums.

## Layout

| Path | Purpose |
|---|---|
| `docker-compose.yml` | Service definition (Podman 4.9 / podman-compose 1.0.6 compatible) |
| `.env.example` | All DMS variables, hardened defaults. `cp .env.example .env && chmod 600 .env` |
| `Dockerfile.fips` | DMS + validated OpenSSL FIPS provider (+ scoped ClamAV exception) |
| `fetch-offline-bundle.sh` | Connected side: download, verify, build and package everything |
| `docker-data/dms/fips/` | System-wide OpenSSL policy (FIPS provider / policy-only variants) |
| `docker-data/dms/config/` | Postfix, Dovecot 2.4 and start-up hook overrides |
| `setup-instructions.md` | **Full guide**: FIPS scope, downloads, EL8 host prep, configuration, maintenance, verification |

## Quick start

```bash
# Connected side (any host with Podman)
./fetch-offline-bundle.sh            # --help for options

# Enclave (EL8, FIPS mode, SELinux enforcing), after transferring and verifying the bundle
sudo ./rpms/install-offline.sh
sudo podman load -i images/dms-fips-16.0.1.tar
cp .env.example .env && chmod 600 .env   # then edit
sudo podman-compose up -d
```

Read **[setup-instructions.md](setup-instructions.md)** before deploying. Section 1 explains exactly what is and isn't
inside the FIPS boundary.

> Note: FIPS 140-2 certificates moved to the CMVP Historical list on 21 Sep 2026. Validate the compliance
> claim for your system with your assessor.
