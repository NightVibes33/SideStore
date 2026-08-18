# Apple-ID signing worker

This worker is the real macOS side of the SideStore Web signing architecture.

## What it does

1. Runs on a Mac with Xcode command-line tools and `fastlane`.
2. Authenticates to Apple using the supplied Apple ID email.
3. Lets `fastlane`/Spaceship perform Apple's normal interactive 2FA challenge locally.
4. Uses `fastlane cert` to obtain/install an Apple development signing identity when needed.
5. Uses `fastlane sigh --development` to obtain the development provisioning profile for the requested bundle identifier.
6. Signs the IPA with the resulting Apple Development identity.
7. Verifies the signature and emits a new IPA.

Apple ID passwords and 2FA verification codes are intentionally entered on the worker itself. They are never submitted to the SideStore Web gateway or stored in repository files.

## Requirements

- macOS
- Xcode command-line tools
- Ruby/Bundler
- fastlane
- An Apple account authorized to create/use the requested development signing assets

Install fastlane according to its official documentation, then make the script executable:

```sh
chmod +x sign-apple-id.sh
```

Run:

```sh
./sign-apple-id.sh input.ipa com.example.app output.ipa you@example.com
```

The first Apple interaction may ask for the Apple ID password and Apple's 2FA verification code in the worker terminal. Subsequent runs may reuse fastlane's authenticated session until Apple requires verification again.

## Gateway integration

Set `SIGNER_URL` on the web gateway to an authenticated HTTPS worker adapter. The adapter should accept a job containing the IPA path and bundle identifier and execute this worker locally. Do not expose the worker directly to the public internet.

SideStore itself still uses native iOS components and LocalDevVPN for device installation. A web page can generate and serve an HTTPS OTA manifest, but it cannot reproduce those native privileged installation mechanisms in Safari.
