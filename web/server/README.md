# SideStore Web Signing Gateway

This service is the privileged bridge between the static PWA and a separately deployed signer.

## Run

```bash
npm install
PUBLIC_ORIGIN=https://sign.example.com WEB_ORIGIN=https://nightvibes33.github.io SIGNER_URL=http://127.0.0.1:9000 npm start
```

Set `API_TOKEN` and require the browser to send `Authorization: Bearer <token>` if the gateway is exposed publicly.

## Signer responsibility

`SIGNER_URL` is intentionally an adapter boundary. It must perform the Apple-account authentication, device/provisioning operations, and code-signing operations required by the distribution method you are authorized to use. The gateway does not retain Apple passwords or verification codes.

The adapter receives a job containing the temporary IPA path and app metadata. It may return `verification_required` plus a session ID. The gateway forwards the user's short-lived verification code to the adapter and then polls the job.

On success, the adapter must return:

```json
{"status":"complete","signedFile":"/absolute/path/to/signed.ipa"}
```

The gateway then exposes an HTTPS manifest and an `itms-services://` installation URL for the completed job. Availability of that installation mechanism depends on Apple's current signing/distribution rules.
