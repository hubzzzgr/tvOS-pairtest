# Validation and unresolved limitations

## Evidence boundaries

No physical iPhone, Apple TV, or LiveContainer session has been used during this Windows implementation. CI verifies compilation, synthetic protocol behavior and a simulator launch only. No real pairing record or device identity is included in this repository.

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
| tvOS 26 | Current reference protocol path inspected; no explicit local compatibility proof | Unknown |
| tvOS 27 | Current reference protocol path inspected; no explicit local compatibility proof | Unknown |

The current upstream implementations document Apple TV manual pairing, but their iOS 27 support does not itself establish tvOS 27 compatibility or this app's interoperability. Record exact product/version/build and all independent results during each physical test.

## Known boundaries and exact failure locations

- `RemotePairingClient.authenticate`: wire version other than 19 yields `Unsupported: peer wire protocol version …`; non-AppleTV handshake models stop the new PIN flow. Missing/malformed TLVs stop the exchange. A server proof or peer signature mismatch yields `Cryptographic authentication failed` and no record.
- `RemotePairingClient.authenticate/verify`: legacy records without `tvpair_peer_public_key` / `tvpair_peer_identifier` yield `Unsupported: this imported record lacks the peer signing key…`. This intentionally prevents silently accepting unauthenticated peer identity.
- `RemotePairingClient.receiveTLV`: generic `pairingRejectedWithError` events use local sentinel `-1` when no TLV error code is available. This sentinel is not a device-reported CoreUtils error code. Raw localized error payloads are omitted to keep credentials out of logs.
- `RemotePairingClient.createTunnelListener`: no validated listener port yields `Unsupported: the authenticated endpoint did not provide a TCP tunnel listener…`. The saved pairing remains available for reconnect on the regular advertisement. Manual pairing and tunnel availability are separate.
- `TCPTransport.init(preSharedKey:)`: first CI found `type 'tls_ciphersuite_t' has no member 'TLS_PSK_WITH_AES_256_CBC_SHA384'` and the corresponding AES-128 name. The implementation now uses the deprecated public numeric `SSLCipherSuite` configuration API. An iOS build accepting that API does not prove runtime cipher support; actual failures surface as `Network error (TLS, …)`, POSIX/DNS codes, timeout, or closure. No successful PSK negotiation has been observed on hardware here.
- `TrustedTunnel.establish`: an unexpected CDTunnel configuration yields `Unexpected protocol response: CDTunnel handshake configuration`. No system tunnel or route is installed.
- `TunnelTCPStream`: the bounded userspace transport is not a production network stack. IPv6 extensions, zero-window conditions, unexpected ACKs, receive limits or timeouts fail explicitly. Separate developer/RSD streams are sequential and limited; a busy RSD peer may expose additional multiplexing requirements.
- `RemoteXPCTransport.receive`: bounded HTTP/2 and XPC support may encounter newer object/frame types. These return `Unsupported: XPC object tag` / `HTTP/2 frame type`; no raw protocol data enters logs. Full general-purpose flow control and file transfer are out of scope.
- `DeveloperServiceClient.inspect`: an RSD reply without the device-info service is blocked; getdeviceinfo must return `CoreDevice.output` to pass. Actual tvOS DDI/CoreDevice version interoperability is unverified. Missing properties remain `Unavailable`.
- `KeychainStorage`: actual access-group restrictions depend on guest signing and the host. OSStatus is shown; file fallback requires explicit consent and is separately scoped. Host access and secure zeroization of Swift memory cannot be guaranteed.
- `BonjourDiscovery`: browsing continues until stopped. Empty results cannot distinguish a TV being asleep, multicast isolation, missing service exposure or denied policy. Known DNS-SD policy denial is explained. Hostname resolution re-runs periodically; no stable identity is inferred from names/IPs.

## Acceptance tracking

- Implemented: native dark SwiftUI interface; user-initiated discovery; live service updates; resolved endpoints; IPv4/IPv6/manual input; actual TCP attempts; PIN challenge gating; cryptographic Pair-Setup/Pair-Verify; storage/import/delete/export; explicit protected-file fallback; independent diagnostics; cancellation/timeouts; trusted-listener/TLS/CDTunnel test; userspace RSD and developer-info attempt; unsigned CI packaging.
- CI verified: arm64 compilation, all 29 tests, unsigned IPA artifact and simulator launch, as recorded above. Structured network/Keychain error codes survive log redaction independently of free-text messages.
- Requires hardware: launch/permission behavior on iOS 27 and LiveContainer; actual Apple TV discovery; authenticated pairing; stored-record reuse; cross-tool export compatibility; TLS-PSK support; trusted tunnel; RemoteXPC developer-service response.
- No device evidence means the primary no-VPN feasibility question remains unanswered. Failed stages are useful experimental evidence only when gathered from an actual device run.

## Recommended next experiments

Run standalone first, then repeat in LiveContainer with the same Apple TV and OS build. Compare discovery, TCP, authentication, Keychain and tunnel checks independently. If public TLS-PSK fails, establish the exact TLS error and offered cipher/version before changing transport code. If the userspace stream fails, capture synthetic fixtures or sanitized packet structure without keys/PINs and extend that module in isolation. Do not proceed to IPA installation, app signing or refreshing until a hardware run proves the authenticated developer-service connection.
