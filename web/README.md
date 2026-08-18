# SideStore Web

A mobile-first Progressive Web App for the SideStore project. It is deliberately separate from the native iOS target: the native app remains responsible for device-side capabilities while this client provides a browser/Home Screen interface.

## GitHub Pages

The `web-pages.yml` workflow publishes this directory to GitHub Pages whenever `web-pwa` changes.

## Signing service contract

The PWA does not store Apple credentials or verification codes. Configure an HTTPS signing service in **Settings**.

Expected endpoints:

- `POST /auth/start` → `{ "status": "verification_required", "sessionId": "..." }` or `{ "status": "authenticated" }`
- `POST /auth/2fa` → `{ "sessionId": "...", "code": "..." }`
- `GET /devices` → `{ "devices": [{ "name": "...", "udid": "...", "status": "registered" }] }`

The signing service is responsible for Apple authentication, provisioning, signing, device registration, and any Apple-required distribution flow. The browser client only sends short-lived session information over HTTPS.

## Native iOS installation

Do not treat a generic IPA download as equivalent to Apple's current web-distribution system. Apple documents MarketplaceKit/web distribution as requiring approved distribution, a registered domain, an alternative distribution key, install verification tokens, and server-side licensing where applicable. See Apple's current documentation before enabling a production install endpoint.

## Local data

Selected IPAs are stored in IndexedDB for the current browser. They are not uploaded merely by selecting them. Upload/signing behavior should be implemented by the signing service endpoint once that backend is available.
