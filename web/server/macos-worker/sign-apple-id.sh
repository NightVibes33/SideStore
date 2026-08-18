#!/bin/bash
set -euo pipefail

# SideStore Web authorized macOS signing worker.
# Apple ID authentication happens locally through fastlane Spaceship.
# Passwords/2FA codes are entered only into the worker terminal and are not
# accepted by or transmitted through the web gateway.
#
# Usage:
#   ./sign-apple-id.sh input.ipa com.example.app output.ipa apple@example.com
#
# Requirements: macOS, Xcode command-line tools, Ruby/Bundler, fastlane.

INPUT_IPA="${1:?input IPA required}"
BUNDLE_ID="${2:?bundle identifier required}"
OUTPUT_IPA="${3:?output IPA required}"
APPLE_ID="${4:?Apple ID email required}"

command -v fastlane >/dev/null || { echo "fastlane is required" >&2; exit 2; }
command -v codesign >/dev/null || { echo "codesign is required" >&2; exit 2; }
command -v security >/dev/null || { echo "security is required" >&2; exit 2; }
command -v ditto >/dev/null || { echo "ditto is required" >&2; exit 2; }

WORK="$(mktemp -d -t sidestore-worker)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/payload"

# Fastlane/Spaceship performs the Apple ID login and, when required, prompts
# locally for Apple's 2FA verification code. No code is accepted as an HTTP
# request by this worker.
echo "Authenticating with Apple ID on this macOS worker..."
fastlane cert -u "$APPLE_ID"
fastlane sigh -u "$APPLE_ID" -a "$BUNDLE_ID" --development --skip_install -o "$WORK"

PROFILE="$(find "$WORK" -maxdepth 1 -type f \( -name '*.mobileprovision' -o -name '*.provisionprofile' \) -print -quit)"
[ -n "$PROFILE" ] || { echo "No development provisioning profile returned by Apple." >&2; exit 3; }

IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development:/{print $2; exit}')"
[ -n "$IDENTITY" ] || { echo "No Apple Development signing identity is installed." >&2; exit 4; }

echo "Using signing identity: $IDENTITY"

unzip -q "$INPUT_IPA" -d "$WORK/payload"
APP_PATH="$(find "$WORK/payload/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
[ -n "$APP_PATH" ] || { echo "IPA does not contain Payload/*.app" >&2; exit 5; }
cp "$PROFILE" "$APP_PATH/embedded.mobileprovision"

# Sign nested code from deepest path to the application bundle.
find "$APP_PATH" -type d \( -name '*.framework' -o -name '*.appex' -o -name '*.app' -o -name '*.xpc' \) -print0 \
  | xargs -0 -n1 printf '%s\n' \
  | awk '{print length($0),$0}' | sort -rn | cut -d' ' -f2- \
  | while IFS= read -r BUNDLE; do
      codesign --force --sign "$IDENTITY" --timestamp=none "$BUNDLE"
    done

codesign --force --sign "$IDENTITY" --timestamp=none --deep "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

rm -f "$OUTPUT_IPA"
ditto -c -k --sequesterRsrc --keepParent "$WORK/payload/Payload" "$OUTPUT_IPA"

echo "SIGNED_IPA=$OUTPUT_IPA"
