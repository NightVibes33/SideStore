# Security requirements

- Run the gateway only over HTTPS.
- Keep `API_TOKEN` server-side; never commit it.
- Do not log Apple passwords, verification codes, cookies, session tokens, or raw authentication responses.
- Delete uploaded IPA files after the signer has produced its result and after any required download window expires.
- Restrict CORS to the deployed PWA origin in production.
- Put the Apple-account-specific signer behind a private network boundary when possible.
- Treat verification codes as one-time, short-lived credentials.
- Do not use this service to bypass Apple's licensing, provisioning, or distribution controls.
