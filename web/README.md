# SideStore Web

Mobile-first PWA companion for the SideStore project. It reproduces the app-library, IPA upload, signing-job, device, verification, and installation workflow in Safari/Home Screen UI while leaving privileged Apple operations to a separate HTTPS signing gateway.

## GitHub Pages

`.github/workflows/web-pages.yml` publishes `web/` to GitHub Pages. The Pages site is static and contains no Apple credentials.

## Signing gateway

Run `web/server` on infrastructure that can reach your configured signer. GitHub Pages cannot execute the signing worker itself.

```bash
cd web/server
npm install
PUBLIC_ORIGIN=https://sign.example.com \
WEB_ORIGIN=https://owner.github.io \
SIGNER_URL=http://127.0.0.1:9000 \
npm start
```

Optional `API_TOKEN` protects the `/v1` routes. The browser sends the IPA as multipart form data. The gateway stores the upload temporarily, forwards job metadata to the signer, and exposes job status, device information, an OTA manifest, and the completed signed IPA.

### Signer adapter contract

The gateway deliberately does **not** collect or persist an Apple ID password. The `SIGNER_URL` service is responsible for the Apple-account-specific operation and may return:

```json
{"status":"verification_required","sessionId":"..."}
```

After the user enters the short-lived verification code, the gateway forwards:

```json
{"sessionId":"...","code":"..."}
```

to `POST /v1/auth/verify` on the signer. A successful signing result must return `status: "complete"` and a `signedFile` path accessible to the gateway.

Required adapter endpoints:

- `POST /v1/jobs`
- `POST /v1/auth/verify`
- `POST /v1/devices`

The adapter must implement Apple's current authentication, provisioning, and signing requirements. Do not expose Apple passwords or verification codes in logs, URLs, analytics, or persistent browser storage.

## Installation

For a completed job the gateway generates an HTTPS `manifest.plist` and an `itms-services://` installation URL. Whether that installation path is permitted for a particular app/device is determined by Apple's current distribution and provisioning rules; the web UI does not bypass those rules.

## PWA

Safari users can use **Share → Add to Home Screen**. The web manifest and service worker provide standalone Home Screen behavior and offline caching of the application shell.
