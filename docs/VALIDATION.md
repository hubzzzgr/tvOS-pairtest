# Validation and unresolved limitations

## Evidence boundaries

The implementation environment remains Windows. There has been no agent-operated physical iPhone or Apple TV test. User-reported LiveContainer observations are recorded separately below; the build-2 retest now shows the app reporting successful onboarding authentication and record persistence. CI verifies compilation, synthetic protocol behavior and simulator launch only. No real pairing credentials are included in this repository.

## User-reported build-4 retest and build-5 developer tests — 2026-11-07

The user's screenshot on an **iPhone15,4 / iOS 27.0.1** shows pairing, persistence, trusted tunnel establishment and RSD device-information retrieval passing inside LiveContainer. Developer-service availability is blocked while RSD advertises `com.apple.instruments.dtservicehub`; the name is unavailable. Build 4 tested only CoreDevice deviceinfo and only read `DeviceName` from RSD, explaining both limitations. These observations are user-reported; no agent-operated physical test or Apple TV result is established.

Build 5 probes the native Instruments DTX hub with a capability exchange, deviceinfo channel and read-only running-process request. Advertisement alone is insufficient. It can show the saved pairing-record name with explicit provenance when RSD omits the name. The result retains the connection and offers explicit TikTok/Instagram Pause and Resume tests using exact bundle-ID lookup, immediate PID recheck and acknowledged suspend/resume requests. It does not claim an acknowledged request proves suspension. Physical DTX/process-control interoperability, including permissions for these App Store apps, remains unverified.

## User-reported build-3 retest and build-4 transport change — 2026-11-07

The next screenshots show onboarding initiation, authentication and persistence passing, followed by `Unsupported: TLS did not negotiate one of the required pre-shared-key cipher suites`. Reaching this guard implies that the outbound saved-record verification returned successfully and an authenticated listener port was received. The screenshot does not contain the negotiated numeric suite or prove a valid PSK tunnel; no developer-service success is claimed. The incoming resolution row was incorrectly left as blocked even though a later outbound connection had resolved.

Build 4 replaces the system TLS experiment with a bundled OpenSSL TLS 1.2 PSK adapter, retains full Finished/cipher verification and requires CDTunnel before tunnel success. It records precise listener/TLS/CDTunnel progress with numeric OpenSSL reasons, labels initial incoming DNS lookup as not attempted, and forwards actual successful outbound resolution to that row. Physical LiveContainer/tvOS interoperability remains to be tested.

## User-reported build-2 retest and build-3 corrections — 2026-11-07

The user tested all three actions against the same other iPhone from LiveContainer. The incoming onboarding result shows authentication and record persistence passing, followed by a failed outbound handshake. Selecting the saved record independently reports `Unexpected protocol response: handshake peerDeviceInfo`. A TCP-only test passes discovery, endpoint resolution and TCP. These are user-provided screenshots, not agent-observed protocol captures; the exact target OS and returned handshake fields remain unknown. They establish neither trusted tunnel nor developer-service success.

Inspection found that outbound verification unnecessarily required an unverified handshake model even when a saved, pinned peer identity was available. Build 3 requires the handshake response envelope, but permits absent descriptive peer metadata during saved-record Pair-Verify. The pinned peer key, identifier, signature and encrypted proofs remain required. New Apple TV PIN setup still requires an AppleTV model. A malformed response envelope now has its own specific error instead of being conflated with missing metadata.

The follow-up reconnect after initial authentication now reports under the tunnel check; it cannot overwrite completed pairing initiation/authentication results or mark the tunnel passed. TCP-only results say **TCP connection succeeded** and label excluded checks **Not attempted**. The incoming result offers **Retry saved-record connection** when a record and matching endpoint are available, retaining the onboarding channel across repeated retries. Dismissing the result still ends that session. Build-3 physical reconnect/tunnel behavior awaits retest.

## User-reported LiveContainer evidence and build-2 corrections — 2026-11-07

The user supplied screenshots from LiveContainer while testing another iPhone. They show a discovered regular Remote Pairing service on `iPhone.local.:49152`; Bonjour discovery, endpoint resolution and TCP passed. The peer closed before pairing initiation completed. A simultaneous blanket Local Network warning was therefore misleading. These observations do not prove authenticated pairing or an Apple TV result.

Build 2 tracks browser failures per service, suppresses blanket permission warnings after successful discovery, distinguishes regular/saved-record endpoints from Apple TV manual setup, and adds explicit device-initiated iOS 27/iPadOS 27 onboarding. Its listener advertisement can still be blocked by LiveContainer's host declarations; successful browsing of a different service does not establish publishing permission. The new onboarding implementation remains physically unvalidated until a user repeats the test with build 2.

## Recorded build-4 CI evidence — 2026-11-07

[CI run 42347425656](https://github.com/hubzzzgr/tvOS-pairtest/actions/runs/42347425656) succeeded for source `89ef828fd5013adde51d6a1483503609a1288400`:

- All **52 tests** passed with zero failures. Seven PSK tests used a separate OpenSSL **3.5.9** CLI server over real loopback TCP; the client used the bundled OpenSSL **3.6.5** memory-BIO adapter. Both 0x00AF and 0x008C completed handshake and encrypted round trips, including multi-record payloads and Data slices. Wrong PSKs, an unconfigured suite and tampered ciphertext were rejected. Read timeout and cancellation passed. No TLS integration test was skipped.
- iOS arm64 archive, unsigned packaging, simulator build, installation and launch passed with Xcode 16.4 / Swift 6.1.2 / iOS 18.5 SDK. The simulator successfully loaded the embedded OpenSSL framework; its home-screen screenshot was downloaded and visually reviewed.
- The packaged app has build **4**, minimum OS **17.0**, all five Bonjour declarations, zero app extensions and bundled MIT/Apache notices. The app executable and OpenSSL framework are arm64 Mach-O files without code-signature load commands. The distributor's framework signature is removed from the release copy.
- The **2,533,949-byte** IPA's SHA-256 matches CI's manifest and GitHub's uploaded release digest: `e15c7f02c2eabaafb79b034ca9cf2e2e9c65b6b6a7e05ee763e19b5bc99b713a`.
- [Public prerelease and direct download](https://github.com/hubzzzgr/tvOS-pairtest/releases/tag/build-4) target the tested source revision. Loopback TLS interoperability does not establish a physical CDTunnel or developer-service result on iOS/tvOS; the user's LiveContainer retest remains required.

## Recorded build-3 CI evidence — 2026-11-07

[CI run 42345217207](https://github.com/hubzzzgr/tvOS-pairtest/actions/runs/42345217207) succeeded for source `d6a1093b8c346b17f4bb8ff18a2ce51ca0093eeb`:

- All **45 tests** passed with zero failures. New cases cover saved-record verification/listener creation without a handshake model or any peer metadata, rejection of a bad peer signature despite missing metadata, rejection of a malformed handshake envelope, the retained AppleTV model requirement for new setup, and reconnect-report isolation from completed setup checks.
- iOS arm64 archive, unsigned IPA packaging, simulator installation and launch passed with Xcode 16.4 / Swift 6.1.2 / iOS 18.5 SDK. The simulator screenshot was downloaded and visually reviewed.
- Local IPA inspection confirms build **3**, minimum OS **17.0**, all five Bonjour declarations, an unsigned arm64 Mach-O, zero app extensions and bundled license notices.
- The 515,579-byte IPA's SHA-256 matches both CI's manifest and GitHub's uploaded release digest: `f50e51b99b5fda8f06b897890ff82e72a2066d0a70697ceb7f4a471539db3a9c`.
- [Public prerelease and direct download](https://github.com/hubzzzgr/tvOS-pairtest/releases/tag/build-3) target the tested source revision. Successful physical saved-record verification, trusted tunnel establishment and developer-service access remain unverified.

## Recorded build-2 CI evidence — 2026-11-07

[CI run 42342005534](https://github.com/hubzzzgr/tvOS-pairtest/actions/runs/42342005534) succeeded for source `e91ab7618bc6dc713399264c92152ef3404c95a4`:

- All **39 tests** passed, including reverse-role device-initiated setup, rejection of bad client proofs and peer signatures, the independent server SRP vector, incoming pairing state transitions, regular-endpoint bootstrap gating, compatible version ranges, and the successful-discovery/failed-browser regression.
- iOS arm64 archive, unsigned IPA packaging, simulator installation and launch passed with Xcode 16.4 / Swift 6.1.2 / iOS 18.5 SDK.
- The simulator screenshot was visually reviewed. The header reports network path availability without claiming a permission check. No fabricated devices are shown.
- The downloaded IPA was checked as arm64 and unsigned, with zero app extensions and bundled license notices. Its compiled Info.plist has build number **2**, minimum OS **17.0**, and all five Bonjour service declarations including `_remotepairing-pairable-host._tcp`.
- SHA-256 matches CI's manifest: `4227153ea3b226c34fd2dd279656e0de696620154c0bdc1ff5022cfef7a034e8`.
- [Public experimental prerelease and direct IPA download](https://github.com/hubzzzgr/tvOS-pairtest/releases/tag/build-2) use that source revision. These synthetic/CI results do not establish successful pairing inside the user's LiveContainer environment; a physical retest remains required.

## Recorded CI evidence — 2026-11-06

[Build 42282294917](https://github.com/hubzzzgr/tvOS-pairtest/actions/runs/42282294917) completed successfully for source revision `d149ee85dbb8938eb489dd2df20c499f2aa4659f`:

- Xcode 16.4 (16F6), Swift 6.1.2, iOS 18.5 SDK, deployment target iOS 17.
- 29 XCTest tests passed with zero failures, including synthetic full Pair-Setup and Pair-Verify, tampered proofs/signatures, independent SRP client/server vectors, mDNS identity vectors, userspace IPv6/TCP packets, frame reassembly, storage errors, sanitization, loopback timeouts and cancellation.
- The iOS arm64 archive succeeded. The unsigned IPA was uploaded as `TVPair-unsigned-arm64`.
- Simulator build, installation and launch succeeded on an iOS 18.5 iPhone simulator. The final screenshot was downloaded and visually reviewed; it shows the real empty discovery interface, without fabricated devices.
- Downloaded IPA verified locally: 64-bit arm64 Mach-O, no code-signature load command, zero app extensions, bundled license notices. SHA-256 matches CI's manifest: `b0526ebd4b282e9f113074dc023096a4eb3c79e305b76150c00cc70dcaedb22e` (448,144 bytes).
- Source links, logs, result bundles and screenshot are retained in the run's artifacts. The artifact's 14-day retention is not a permanent release; the workflow can regenerate the app.

This evidence does not prove iOS 27 runtime compatibility, LiveContainer guest behavior, tvOS interoperability, or a physical authenticated developer-service connection.

| Target | Build/runtime evidence | Pairing + trusted developer-service evidence |
| --- | --- | --- |
| iOS 17 deployment target / arm64 | Archive passed using iOS 18.5 SDK; iOS 18.5 simulator launch passed | Physical test outstanding |
| iOS 27 standalone | No physical test | Unknown |
| iOS 27 in LiveContainer | No physical test; host permissions/Keychain unverified | Unknown |
| User's two-iPhone LiveContainer setup (target OS not reported) | Screenshots show discovery, resolution and TCP passing | Build-3 onboarding authentication/persistence passed; code progressed through saved-record verification and listener creation to the TLS suite guard; no trusted tunnel/developer result |
| tvOS 26 | Current reference protocol path inspected; no explicit local compatibility proof | Unknown |
| tvOS 27 | Current reference protocol path inspected; no explicit local compatibility proof | Unknown |

The current upstream implementations document Apple TV manual pairing, but their iOS 27 support does not itself establish tvOS 27 compatibility or this app's interoperability. Record exact product/version/build and all independent results during each physical test.

## Known boundaries and exact failure locations

- `RemotePairingClient.authenticate`: an advertised version range excluding the requested 19 yields `Unsupported: no compatible RPPairing wire version…`. A newer maximum alone is accepted when 19 remains supported. Non-AppleTV models stop the outbound TV PIN flow; iPhone onboarding instead uses `PairableHostSession`. Missing/malformed TLVs stop the exchange. A proof or peer signature mismatch yields `Cryptographic authentication failed` and no record.
- `RemotePairingClient.authenticate/verify`: legacy records without `tvpair_peer_public_key` / `tvpair_peer_identifier` yield `Unsupported: this imported record lacks the peer signing key…`. This intentionally prevents silently accepting unauthenticated peer identity.
- `RemotePairingClient.receiveTLV`: generic `pairingRejectedWithError` events use local sentinel `-1` when no TLV error code is available. This sentinel is not a device-reported CoreUtils error code. Raw localized error payloads are omitted to keep credentials out of logs.
- `RemotePairingClient.createTunnelListener`: no validated listener port yields `Unsupported: the authenticated endpoint did not provide a TCP tunnel listener…`. The saved pairing remains available for reconnect on the regular advertisement. Manual pairing and tunnel availability are separate.
- `PSKTLSTransport` / `TVPairTLS`: build 4 uses bundled OpenSSL with only the two reference TLS 1.2 PSK suites, a per-connection PSK callback and authenticated memory-BIO I/O. Protocol failures export a numeric OpenSSL reason, while POSIX/DNS failures and deadlines remain distinct. The earlier system-TLS cipher guard failed on the user's hardware. Physical PSK/CDTunnel success with the replacement is still unproven; compilation or loopback interoperability alone is insufficient.
- `TrustedTunnel.establish`: an unexpected CDTunnel configuration yields `Unexpected protocol response: CDTunnel handshake configuration`. No system tunnel or route is installed.
- `TunnelTCPStream`: the bounded userspace transport is not a production network stack. IPv6 extensions, zero-window conditions, unexpected ACKs, receive limits or timeouts fail explicitly. Separate developer/RSD streams are sequential and limited; a busy RSD peer may expose additional multiplexing requirements.
- `RemoteXPCTransport.receive`: bounded HTTP/2 and XPC support may encounter newer object/frame types. These return `Unsupported: XPC object tag` / `HTTP/2 frame type`; no raw protocol data enters logs. Full general-purpose flow control and file transfer are out of scope.
- `DeveloperServiceClient.inspect`: an RSD reply without the device-info service is blocked; getdeviceinfo must return `CoreDevice.output` to pass. Actual tvOS DDI/CoreDevice version interoperability is unverified. Missing properties remain `Unavailable`.
- `KeychainStorage`: actual access-group restrictions depend on guest signing and the host. OSStatus is shown; file fallback requires explicit consent and is separately scoped. Host access and secure zeroization of Swift memory cannot be guaranteed.
- `BonjourDiscovery`: browsing continues until stopped. Empty results cannot distinguish a TV being asleep, multicast isolation, missing service exposure or denied policy. Known DNS-SD policy denial is explained. Hostname resolution re-runs periodically; no stable identity is inferred from names/IPs.

## Acceptance tracking

- Implemented: native dark SwiftUI interface; user-initiated discovery; live service updates; resolved endpoints; IPv4/IPv6/manual input; actual TCP attempts; PIN challenge gating; cryptographic Pair-Setup/Pair-Verify; storage/import/delete/export; explicit protected-file fallback; independent diagnostics; cancellation/timeouts; trusted-listener/TLS/CDTunnel test; userspace RSD and developer-info attempt; unsigned CI packaging.
- CI verified: build 2 arm64 compilation, all 39 tests, unsigned IPA and simulator launch, as recorded above. Structured network/Keychain error codes survive log redaction independently of free-text messages.
- Requires hardware: launch/permission behavior on iOS 27 and LiveContainer; actual Apple TV discovery; authenticated pairing; stored-record reuse; cross-tool export compatibility; TLS-PSK support; trusted tunnel; RemoteXPC developer-service response.
- No device evidence means the primary no-VPN feasibility question remains unanswered. Failed stages are useful experimental evidence only when gathered from an actual device run.

## Recommended next experiments

Run standalone first, then repeat in LiveContainer with the same Apple TV and OS build. Compare discovery, TCP, authentication, Keychain and tunnel checks independently. If public TLS-PSK fails, establish the exact TLS error and offered cipher/version before changing transport code. If the userspace stream fails, capture synthetic fixtures or sanitized packet structure without keys/PINs and extend that module in isolation. Do not proceed to IPA installation, app signing or refreshing until a hardware run proves the authenticated developer-service connection.
