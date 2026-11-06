# Validation and unresolved limitations

## Evidence boundaries

No physical iPhone, Apple TV, or LiveContainer session has been used during this Windows implementation. CI verifies compilation, synthetic protocol behavior and a simulator launch only. No real pairing record or device identity is included in this repository.

| Target | Build/runtime evidence | Pairing + trusted developer-service evidence |
| --- | --- | --- |
| iOS 17+ arm64 | See GitHub Actions for exact Xcode/SDK/build result | Physical test outstanding |
| iOS 27 standalone | No physical test | Unknown |
| iOS 27 in LiveContainer | No physical test; host permissions/Keychain unverified | Unknown |
| tvOS 26 | Current reference protocol path inspected; no explicit local compatibility proof | Unknown |
| tvOS 27 | Current reference protocol path inspected; no explicit local compatibility proof | Unknown |

The current upstream implementations document Apple TV manual pairing, but their iOS 27 support does not itself establish tvOS 27 compatibility or this app's interoperability. Record exact product/version/build and all independent results during each physical test.

## Known boundaries and exact failure locations

- `RemotePairingClient.authenticate`: wire version other than 19 yields `Unsupported: peer wire protocol version …`; non-AppleTV handshake models stop the new PIN flow. Missing/malformed TLVs stop the exchange. A server proof or peer signature mismatch yields `Cryptographic authentication failed` and no record.
- `RemotePairingClient.authenticate/verify`: legacy records without `tvpair_peer_public_key` / `tvpair_peer_identifier` yield `Unsupported: this imported record lacks the peer signing key…`. This intentionally prevents silently accepting unauthenticated peer identity.
- `RemotePairingClient.createTunnelListener`: no validated listener port yields `Unsupported: the authenticated endpoint did not provide a TCP tunnel listener…`. The saved pairing remains available for reconnect on the regular advertisement. Manual pairing and tunnel availability are separate.
- `TCPTransport.init(preSharedKey:)`: public Network/Security TLS-PSK configuration is experimental. An iOS build accepting the symbols does not prove runtime cipher support; actual failures surface as `Network error (TLS, …)`, POSIX/DNS codes, timeout, or closure. No successful PSK negotiation has been observed on hardware here.
- `TrustedTunnel.establish`: an unexpected CDTunnel configuration yields `Unexpected protocol response: CDTunnel handshake configuration`. No system tunnel or route is installed.
- `TunnelTCPStream`: the bounded userspace transport is not a production network stack. IPv6 extensions, zero-window conditions, unexpected ACKs, receive limits or timeouts fail explicitly. Separate developer/RSD streams are sequential and limited; a busy RSD peer may expose additional multiplexing requirements.
- `RemoteXPCTransport.receive`: bounded HTTP/2 and XPC support may encounter newer object/frame types. These return `Unsupported: XPC object tag` / `HTTP/2 frame type`; no raw protocol data enters logs. Full general-purpose flow control and file transfer are out of scope.
- `DeveloperServiceClient.inspect`: an RSD reply without the device-info service is blocked; getdeviceinfo must return `CoreDevice.output` to pass. Actual tvOS DDI/CoreDevice version interoperability is unverified. Missing properties remain `Unavailable`.
- `KeychainStorage`: actual access-group restrictions depend on guest signing and the host. OSStatus is shown; file fallback requires explicit consent and is separately scoped. Host access and secure zeroization of Swift memory cannot be guaranteed.
- `BonjourDiscovery`: browsing continues until stopped. Empty results cannot distinguish a TV being asleep, multicast isolation, missing service exposure or denied policy. Known DNS-SD policy denial is explained. Hostname resolution re-runs periodically; no stable identity is inferred from names/IPs.

## Acceptance tracking

- Implemented: native dark SwiftUI interface; user-initiated discovery; live service updates; resolved endpoints; IPv4/IPv6/manual input; actual TCP attempts; PIN challenge gating; cryptographic Pair-Setup/Pair-Verify; storage/import/delete/export; explicit protected-file fallback; independent diagnostics; cancellation/timeouts; trusted-listener/TLS/CDTunnel test; userspace RSD and developer-info attempt; unsigned CI packaging.
- Requires a passing CI run: exact arm64 compilation, unit tests, IPA artifact and simulator launch. Consult the linked Actions run and its logs rather than assuming these passed.
- Requires hardware: launch/permission behavior on iOS 27 and LiveContainer; actual Apple TV discovery; authenticated pairing; stored-record reuse; cross-tool export compatibility; TLS-PSK support; trusted tunnel; RemoteXPC developer-service response.
- No device evidence means the primary no-VPN feasibility question remains unanswered. Failed stages are useful experimental evidence only when gathered from an actual device run.

## Recommended next experiments

Run standalone first, then repeat in LiveContainer with the same Apple TV and OS build. Compare discovery, TCP, authentication, Keychain and tunnel checks independently. If public TLS-PSK fails, establish the exact TLS error and offered cipher/version before changing transport code. If the userspace stream fails, capture synthetic fixtures or sanitized packet structure without keys/PINs and extend that module in isolation. Do not proceed to IPA installation, app signing or refreshing until a hardware run proves the authenticated developer-service connection.
