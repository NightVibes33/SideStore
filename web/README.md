# SideStore Web production signing gateway

The static PWA is hosted independently (GitHub Pages is supported). The signing gateway must run on an authorized macOS machine with Xcode command-line tools and an existing Apple development signing identity/provisioning profile.

## Environment

- `PUBLIC_ORIGIN`: public HTTPS origin of the gateway
- `WEB_ORIGIN`: exact HTTPS origin of the PWA
- `API_TOKEN`: optional bearer token for API protection
- `SIGNING_IDENTITY`: installed Apple Development signing identity
- `PROVISION_PROFILE`: path to the matching provisioning profile
- `SIGNING_WORK_DIR`: optional temporary directory
- `PORT`: HTTP port

The gateway intentionally does not collect or persist Apple ID passwords or 2FA codes. Apple authentication and device provisioning must be completed through Apple's supported developer tooling on the authorized signing machine.

## Run

```sh
npm install
SIGNING_IDENTITY='Apple Development: Example (TEAMID)' \\
PROVISION_PROFILE='/path/to/profile.mobileprovision' \\
PUBLIC_ORIGIN='https://sign.example.com' \\
WEB_ORIGIN='https://<user>.github.io/SideStore' \\
npm start
```

The API exposes `/healthz`, `/v1/jobs`, `/v1/jobs/:id`, `/v1/manifest/:id`, `/v1/ipa/:id`, and `/v1/devices`.

## OTA

For a successfully signed and provisioned IPA, the job response includes an `itms-services://` installation URL backed by an HTTPS manifest and IPA endpoint. The target device still has to satisfy Apple's provisioning/signing requirements; OTA does not bypass those requirements.