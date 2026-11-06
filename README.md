# TVPair — tvOS pairing experiment

Native SwiftUI iOS app for testing whether an ordinary iPhone app can discover, authenticate with, and reach Apple TV developer services over local Wi-Fi without a VPN. Minimum deployment target: iOS 17, arm64. No backend, extensions, private frameworks, custom entitlements, installation service, or signing service.

**Status: experimental implementation, awaiting physical-device validation.** A successful CI build or synthetic protocol test does not establish compatibility with tvOS 26, tvOS 27, iOS 27, or LiveContainer. No physical Apple TV result has been recorded. Authentication, persistence, tunnel establishment, developer-service response, and device information are separate checks; TCP connection alone never means paired.

## Build and install

Open `TVPair.xcodeproj` in a compatible Xcode on macOS. The checked-in project needs no project generator or CocoaPods. Its local Swift package resolves the MIT-licensed BigInt 5.7.0 dependency. To regenerate the project after adding app Swift files: `node scripts/generate-project.mjs` (Windows or macOS).

GitHub Actions **Build TVPair** runs automatically on `main` and supports **Run workflow**. It resolves dependencies, runs the core tests on macOS, archives for iOS arm64 with signing disabled, creates `TVPair-unsigned.ipa`, uploads logs and the unsigned build, then attempts a simulator launch with a screenshot. Failed builds retain diagnostic logs and Xcode result bundles.

Download **TVPair-unsigned-arm64** from a successful run's Artifacts section. The IPA is an **unsigned archive**, not an App Store distribution or a directly installable signed app. Import it into a compatible LiveContainer setup, or apply your own local iOS signing and installation process. No Apple Developer certificate is assumed, stored, or uploaded. This project does not implement signing or installation of other apps.

## Test on Apple TV

1. Put the iPhone and Apple TV on the same LAN. Disable Wi-Fi client isolation if it prevents communication.
2. On Apple TV, open **Settings → Remotes and Devices → Remote App and Devices** to expose manual pairing. Developer-service availability may also depend on Developer Mode and the device's developer image state; TVPair does not change either setting.
3. Open TVPair, tap **Scan local network**, and allow Local Network access. In LiveContainer, the host's permission and Bonjour declarations may control guest access.
4. Select a **Manual Remote Pairing** advertisement. Check its resolved hostname, IPv4/IPv6 addresses, service type, and actual port. Names and model TXT records are explicitly unverified.
5. Tap **Pair with this device**. A PIN field appears only after an Apple TV handshake and a manual SRP challenge are received. Enter the six-digit code displayed on the TV. Cancel is available during the attempt. Network phases time out; PIN entry and user consent have a 90-second bound. Retry explicitly after a failure; backoff errors show the advertised delay.
6. Inspect all nine checks. A record is saved only after the SRP server proof, authenticated identity ciphertext, and peer identity signature have verified. The app then requests a tunnel listener and tests TLS-PSK / CDTunnel, RemoteXPC RSD, and a read-only developer device-info request.
7. Some tvOS manual-pairing endpoints reject tunnel listener creation. If this happens after pairing, select the regular **Remote Pairing** advertisement and choose **Reconnect with saved record**. The pinned peer signature is checked before any developer test. Addresses and ports are not assumed stable.
8. On networks without multicast, use **Enter IP address or hostname**, specifying the actual port and service protocol. No default port or successful identity is guessed. Lockdown and RSD advertisements have a TCP-only test.
9. Export **sanitized diagnostics** from the Diagnostics tab. Record the iPhone/iOS version, Apple TV model/tvOS version, standalone vs. LiveContainer, exact failed stage, and error code alongside those logs. Missing device properties show **Unavailable**.

## Pairing records and storage

Records default to a Keychain generic-password vault using `WhenUnlockedThisDeviceOnly`, without an access group or hard-coded bundle identifier. Keychain errors are surfaced. If guest access fails, explicitly select **Use protected file storage…** on Devices. This uses iOS complete file protection and backup exclusion in the current app container. It never silently switches storage or erases the separate Keychain vault. A record whose save fails remains in memory for retry during that app session. The LiveContainer host can potentially inspect the guest's files while unlocked.

Saved records show device identity, pairing date (when known), and import date. Import accepts XML/binary Remote Pairing plists with an Ed25519 key pair and explicit host identifier; USB lockdown plists are rejected. Import never marks a session authenticated. Older reference formats lacking the peer signing key are retained and exportable, but cannot reconnect in TVPair until a fresh PIN pairing establishes that peer identity. See [record format notes](docs/PROTOCOL.md#record-format).

Export requires an explicit confirmation and uses the native iOS share sheet. **Exported records contain private keys.** Temporary share files use complete file protection and are removed when the share sheet closes. Deleting local credentials does not revoke the host on Apple TV. Remove its pairing on the TV separately. No analytics, telemetry, automatic upload, or credential logging is included.

## Development and tests

On macOS:

```sh
swift test --package-path Packages/TVPairCore
xcodebuild -project TVPair.xcodeproj -scheme TVPair -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO ARCHS=arm64 build
```

The package separates discovery, endpoint validation, cancellable Network.framework transport, RPPairing, credential storage, CDTunnel/userspace TCP, and RemoteXPC. Tests use synthetic data and mock transports, plus local loopback sockets where applicable. No production screen uses a mock device or simulated success. Network and protocol work is asynchronous; SRP exponentiation runs off the main actor.

See [protocol and research notes](docs/PROTOCOL.md), [limitations and validation matrix](docs/VALIDATION.md), and [third-party notices](THIRD_PARTY_NOTICES.md). The primary question remains **unproven until a real iPhone/Apple TV run completes authentication and the trusted developer-service test**.
