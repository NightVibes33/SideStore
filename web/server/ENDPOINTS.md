# Endpoints

- `POST /v1/jobs` multipart IPA + metadata
- `POST /v1/auth/verify` short-lived verification code
- `GET /v1/jobs/:id` job status
- `GET /v1/devices` device data from signer
- `GET /v1/manifest/:id` OTA manifest for completed job
- `GET /v1/ipa/:id` completed signed IPA
