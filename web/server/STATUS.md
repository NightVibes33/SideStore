# Implementation status

Implemented in this tree:

- Mobile-first PWA UI
- IndexedDB IPA library
- HTTPS signing-gateway client
- Multipart IPA upload
- Verification challenge UI
- Job polling
- Device list API integration
- OTA manifest generation
- `itms-services://` install-link generation
- GitHub Pages deployment
- Separate signing adapter boundary

Still dependent on deployment-specific infrastructure:

- An authorized Apple-account signing adapter
- Apple's current provisioning/distribution requirements
- Production storage/CDN and cleanup policy

The PWA itself cannot execute native iOS frameworks or act as a macOS signing environment.
