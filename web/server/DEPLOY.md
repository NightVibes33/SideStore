# Deployment checklist

1. Deploy the gateway on infrastructure capable of reaching the signer.
2. Configure `PUBLIC_ORIGIN`, `WEB_ORIGIN`, `SIGNER_URL`, and a random `API_TOKEN`.
3. Use HTTPS end-to-end.
4. Restrict CORS to the GitHub Pages origin.
5. Configure temporary storage cleanup.
6. Verify the signer implements Apple's current authorized provisioning and distribution requirements.
7. Test the PWA with Safari Share → Add to Home Screen.
