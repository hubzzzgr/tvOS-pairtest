# TVPair — tvOS pairing experiment

Native SwiftUI iOS app for testing whether an ordinary iPhone app can discover, authenticate with, and reach Apple TV developer services over local Wi-Fi without a VPN. Includes a separate device-initiated onboarding flow for iOS 27 / iPadOS 27 test devices. Minimum app deployment target: iOS 17, arm64. No backend, extensions, private frameworks, custom entitlements, installation service, or signing service.

**Status: experimental implementation.** The user's iPhone15,4 / iOS 27.0.1 LiveContainer retest passed pairing, persistence, tunnel establishment and RSD information. On Apple TV / tvOS 27.2, the user reports that build 11's app-only setup enabled developer access and paired, and a subsequent saved-record connection worked. The attached first-attempt log verifies PIN pairing and persistence but stops at regular-endpoint lookup before TLS starts; the later reconnect's independent checks were not included in that export. A successful build or one hardware report does not establish general compatibility. Authentication, persistence, tunnel establishment, developer-service response and device information remain separate checks.

The build-3 physical retest reached the TLS tunnel after successful onboarding and saved-record verification, then stopped at the system TLS cipher check. Build 4 replaces that path with a bundled OpenSSL 3.6.5 TLS 1.2 PSK engine over public Network.framework TCP I/O. Only the two reference PSK cipher suites are enabled; OpenSSL verifies the Finished proofs and authenticated records before CDTunnel starts. Physical tunnel and developer-service interoperability still require a retest.

**Latest download: [TVPair build 11 — unsigned IPA](https://github.com/hubzzzgr/tvOS-pairtest/releases/download/build-11/TVPair-unsigned.ipa).** [Release notes and checksum](https://github.com/hubzzzgr/tvOS-pairtest/releases/tag/build-11). Adds an app-only developer bootstrap attempt using direct DNS-SD to the chosen TV, computer-role PIN pairing and verified developer-service access. LiveContainer is not modified. [IPA-only build 42563215182](https://github.com/hubzzzgr/tvOS-pairtest/actions/runs/42563215182) successfully compiled and packaged iOS arm64; unit/protocol tests and simulator checks were **skipped following the user's preference**. Inspection confirmed build 11, seven Bonjour declarations, bundled licenses and unsigned arm64 app/framework binaries. The TV must respond to the new direct lookup and approve pairing; physical success and Developer Settings visibility remain unverified. CI artifacts expire after 14 days; the prerelease provides a direct download.

## Pair with another iPhone or iPad (build 2 and later)

Developer Mode and a regular `_remotepairing._tcp` advertisement do **not** establish new trust. That endpoint is used with an existing record. Attempting Apple's TV PIN flow against it can end with the peer closing before a handshake, as seen in the initial LiveContainer test report.

For iOS 27 / iPadOS 27 targets:

1. In TVPair, tap **Pair with iPhone / iPad**. Keep TVPair in the foreground.
2. On the **other device**, open **Settings → Developer → Paired Macs** and select **TVPair**.
3. After the device requests setup, TVPair displays a six-digit code. Enter it **on the other device**. TVPair does not ask you to type that code locally.
4. Authentication checks the SRP client proof and signed device identity. Only then is a record saved. TVPair looks for that device's regular advertisement by its identity tag, verifies the peer again, and separately tests the trusted tunnel and developer service.
5. Keep the target pairing screen and TVPair's result open while testing. The reference iPhone onboarding path may retain trust only for the active session; saving a record does not guarantee persistent device-side trust after either side restarts.

Build 3 allows saved-record verification without descriptive handshake metadata while still requiring pinned identity/signature verification. A failed follow-up reconnect is reported under the tunnel check, preserving successful onboarding results. Use **Retry saved-record connection** in that result when offered to retry without closing the onboarding channel. A TCP-only result now says **TCP connection succeeded** and marks authentication/tunnel checks **Not attempted**.

This flow follows [idevice's responder implementation](https://github.com/jkcoxson/idevice/blob/89702099f4d7552f704f93b4526756abda319ceb/idevice/src/remote_pairing/responder.rs) and [idevice_pair's documented iPhone Wi-Fi workflow](https://github.com/jkcoxson/idevice_pair#over-wi-fi-with-iphone-or-ipad). iOS 26 and earlier do not gain that onboarding UI simply by enabling Developer Mode. Apple TV continues to use its separate manual-pairing service and TV-displayed code.

In LiveContainer, the **host** must permit `_remotepairing-pairable-host._tcp` advertisement as well as Local Network access. Successful scanning of `_remotepairing` does not prove the host allows every other service type. A failed advertisement is reported specifically for incoming onboarding. The app's Info.plist declares the new service, but a guest cannot force the hosting app's declarations.

Discovery errors are tracked per service type. If any service has been observed during the scan, the blanket Local Network warning is suppressed. Each failing browser's actual service and numeric DNS-SD code remain in Diagnostics. A network path being available is not presented as a permission check.

## Developer services and app pause tests

Build 12 waits up to 20 seconds for the newly paired Apple TV's regular endpoint, consulting same-IP system discovery between bounded direct lookups. It no longer fails the first handoff after one unanswered four-second query. All endpoint hints still require pinned Pair-Verify; the successful pairing record remains saved. If discovery stays unavailable, the result says that TLS was not attempted and advises reconnecting with the saved record without repeating pairing.

**Build 11 adds app-only Apple TV developer setup.** Open the TV's discovery row → **Enable Apple TV developer access**, confirm its numeric IP, keep Remote App and Devices open on the TV, and tap **Enable developer access**. TVPair directly asks that IP for its actual pairing port using a unicast DNS query, performs computer-host PIN pairing, directly resolves the subsequent trusted endpoint, verifies the pinned peer, and attempts the tunnel/developer probe. The action does not patch or replace LiveContainer. It is experimental: the TV must answer and approve pairing, and no mode change or Developer Settings visibility is claimed without device evidence. See [the flow and its limits](docs/APPLE-TV-DEVELOPER-SETUP.md). Earlier host-modification guidance is superseded by this app-only path.

Build 9 fixes the device-details result display: completed checks are stored per discovered service identity with the tested endpoint, protocol and time. A later manual attempt or another service's result no longer appears under an AirPlay/Companion row. Manual pairing entry is checked against currently discovered host/address aliases and ports; a location advertised only as a non-pairing service is rejected before a transport is opened. A pairing advertisement on the same location takes precedence. Unknown locations can still be tried explicitly; a typed protocol hint does not change the server's protocol. RPPairing handshake timeouts now state that TCP connected but the expected protocol did not answer. TXT monitoring consumes the actual callback data so updated model hints reach the icon classifier.

Build 8 expands discovery with AirPlay (`_airplay._tcp`) and Companion (`_companion-link._tcp`); these are discovery/TCP-only endpoints and never receive RPPairing messages. It uses advertised model keys (`model`, `deviceModel`, `modelName`, `rpmd`, `am`) to choose iPhone/iPad/Apple TV/Mac and other device icons, with explicit hostname/name hints when a model is absent. Unknown types use a generic network icon. Neither an icon nor an advertisement authenticates a device. Devices with no supported advertisements can remain absent, including an iPad that is not publishing such a service.

**Set up Apple TV pairing** guides the TV-side steps, lists actual Manual Remote Pairing endpoints and explains the current host configuration. Apple states that [tvOS has no separate Developer Mode switch](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device?changes=_8); Developer Settings appear after pairing. No fake enable switch or unverified AMFI request is added. Manual pairing requires this TV's advertised port, not a port copied from another phone. AirPlay, Companion and lockdown ports are not substitutes.

The supplied diagnostics show regular discovery working while Manual Remote Pairing and RSD searches fail with `-72008` ([missing required Bonjour configuration](https://developer.apple.com/documentation/foundation/netservice/errorcode-swift.enum/missingrequiredconfigurationerror?changes=__4&language=objc)). These specific system-browser failures remain visible without reporting blanket denial. The user identified a customized SideStore-integrated LiveContainer 3.8.11 whose main bundle omits the two declarations. The guest cannot change that installed host. At the user's request, no host patch is used: build 11's explicit developer action instead attempts a targeted direct DNS lookup to the chosen TV IP. This path is independently fallible and unverified on the physical TV; it is not a claim that the browser's configuration error has been repaired.

Build 5 adds a read-only Instruments hub probe alongside CoreDevice deviceinfo. A hub advertisement alone does not pass developer-service availability; the DTX capability handshake, channel request and `runningProcesses` reply must succeed. When RSD omits the name, the saved-record name is shown with **Name source: Saved pairing record**. No Bonjour name is presented as an authenticated device property.

After the Instruments probe passes, the connection result has manual **Pause** and **Resume** tests for TikTok and Instagram. Each action resolves the exact bundle identifier twice, acts only on a stable positive PID and awaits the device's `suspendPid:` / `resumePid:` reply. Acknowledgement is reported separately from a verified frozen state. iOS may refuse process control on App Store apps. Use Resume before finishing the test; closing TVPair does not automatically resume a paused process.

Build 7 also adds **Kill BackBoard…** on the paired device, with an explicit confirmation. It resolves the exact `backboardd` name twice from fresh process lists, confirms its executable name and sends signal 9 using the reply-bearing `sendSignal:toPid:` selector. iOS may refuse system-process control. A successful termination can restart the paired device's graphical session and disconnect the tunnel; a disconnect does not prove termination. No arbitrary process/PID input or automatic termination is exposed.

The authenticated tunnel and Instruments connection stay open while the result is displayed. RSD and Instruments TCP packets are routed to their owning stream with bounded buffering; an idle stream's data is no longer discarded when another service reads.

## Build and install

Open `TVPair.xcodeproj` in Xcode 16.4 or newer on macOS. The checked-in project needs no project generator or CocoaPods. Its local Swift package resolves MIT-licensed BigInt 5.7.0 and Apache-2.0 OpenSSL-Package 3.6.5000 (OpenSSL 3.6.5). Both dependency locks pin exact revisions; SwiftPM also verifies the OpenSSL XCFramework ZIP checksum. Redistribution notices are bundled in the app. To regenerate the project after adding app Swift files: `node scripts/generate-project.mjs` (Windows or macOS).

GitHub Actions **Build TVPair** runs automatically on `main` and supports **Run workflow**. It resolves dependencies, runs the core tests on macOS, archives for iOS arm64 with signing disabled, creates `TVPair-unsigned.ipa`, uploads logs and the unsigned build, then attempts a simulator launch with a screenshot. Failed builds retain diagnostic logs and Xcode result bundles.

For an explicitly requested build without tests, use **Run workflow → ipa_only = true**. This compiles and packages the iPhone IPA while skipping unit/protocol tests and simulator checks. Commits marked `[ipa-only]` skip the automatic push job so the manually dispatched run controls that build. Build 7 uses this mode at the user's request; its new behavior is not covered by a new test run.

Download **TVPair-unsigned-arm64** from a successful run's Artifacts section. The IPA is an **unsigned archive**, not an App Store distribution or a directly installable signed app. Import it into a compatible LiveContainer setup, or apply your own local iOS signing and installation process. No Apple Developer certificate is assumed, stored, or uploaded. This project does not implement signing or installation of other apps.

## Test on Apple TV

1. Put the iPhone and Apple TV on the same LAN. Disable Wi-Fi client isolation if it prevents communication.
2. On Apple TV, open **Settings → Remotes and Devices → Remote App and Devices** to expose manual pairing. Developer-service availability may also depend on Developer Mode and the device's developer image state; TVPair does not change either setting.
3. Open TVPair, tap **Scan local network**, and allow Local Network access. In LiveContainer, the host's permission and Bonjour declarations may control guest access.
4. Select a **Manual Remote Pairing** advertisement. Check its resolved hostname, IPv4/IPv6 addresses, service type, and actual port. Names and model TXT records are explicitly unverified.
5. Tap **Pair with this device**. A PIN field appears only after an Apple TV handshake and a manual SRP challenge are received. Enter the six-digit code displayed on the TV. Cancel is available during the attempt. Network phases time out; PIN entry and user consent have a 90-second bound. Retry explicitly after a failure; backoff errors show the advertised delay.
6. Inspect all nine checks. A record is saved only after the SRP server proof, authenticated identity ciphertext, and peer identity signature have verified. The app then requests a tunnel listener and tests TLS-PSK / CDTunnel, RemoteXPC RSD, and a read-only developer device-info request.
7. After new pairing, TVPair opens a fresh connection and verifies the saved credentials before requesting a tunnel. It can select a regular **Remote Pairing** advertisement when its authentication tag matches the record's identity key. Full peer-signature verification is still required. If that endpoint is unavailable or the manual endpoint rejects tunnel creation, select the regular advertisement yourself and choose **Reconnect with saved record**. Addresses and ports are not assumed stable.
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
