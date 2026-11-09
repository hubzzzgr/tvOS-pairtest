# Developer setup from TVPair inside LiveContainer

The app-only action **Enable Apple TV developer access** was added in build 11.
The previously prepared host-patching helper was removed at the user's request.
No LiveContainer IPA is patched, rebuilt, replaced or installed by this flow.

1. Select the Apple TV's AirPlay/Companion discovery row, open developer setup,
   and confirm its numeric IP. The screen prefers its resolved IPv4 address.
2. Keep Remote App and Devices open on the TV and start the action.
3. TVPair sends a direct unicast DNS PTR query to that single IP, UDP 5353,
   from an ephemeral port. It requests `_remotepairing-manual-pairing._tcp.local`.
   A missing SRV record is followed up by a query for the returned instance.
   It does not use NetServiceBrowser for this step, send multicast packets,
   scan port ranges, or change the host configuration.
4. Only a unique advertised pairing port is used, always on the selected IP.
   A DNS answer cannot redirect the TCP connection to an answer-supplied host.
   DNS is unauthenticated. The existing Apple TV handshake gate, displayed PIN,
   SRP proof, and pinned signing identity checks remain mandatory.
5. The pairing identity uses the reference computer-host role. Successful
   code pairing requests developer trust; it is not reported as proof that
   the Developer Settings menu is visible or any arbitrary mode was toggled.
6. After authenticated setup, TVPair directly resolves the same IP's regular
   `_remotepairing._tcp.local` port and requires pinned peer verification on a
   new connection. TLS-PSK/CDTunnel and a developer-service probe follow.
   Only an actual successful developer probe verifies developer access.

Build 12 gives this handoff a 20-second deadline, checks same-IP regular-service
advertisements between direct lookups, and retries with fresh probes capped at
five seconds each. Tag-matched hints are preferred when available. Full pinned
peer verification is still mandatory even when only an IP/port hint is present.
The user reported successful build-11 developer setup and later saved-record
reuse; its first attempt had stopped after one unanswered direct regular-service
lookup. The change addresses that readiness/discovery window, before TLS starts.

This is an experimental bootstrap attempt, not a verified pre-pair activation
command. It can run before developer trust has been established, but depends
on the TV exposing its pairing service and accepting the TV-code exchange.
It cannot force a responder or bypass TV approval. The direct query may time
out, be denied by Local Network policy, or be unsupported by a TV/router.
Those failures stop explicitly without claiming activation.

The wire format follows RFC 6762 sections 5.5/6.7 and DNS-SD PTR/SRV records.
The implementation bounds packet bytes, record counts, compression traversal,
expanded names, request counts and deadlines. It ignores unrelated transaction
IDs, expired records and unrelated names, and rejects ambiguous port results.
The system Bonjour browser and its separate -72008 diagnostic remain intact.

- [RFC 6762: direct unicast queries and legacy replies](https://www.rfc-editor.org/rfc/rfc6762.html)
- [RFC 6763: DNS-Based Service Discovery](https://www.rfc-editor.org/rfc/rfc6763.html)
- [Reference developer-host RPPairing identity](https://github.com/jkcoxson/idevice/blob/89702099f4d7552f704f93b4526756abda319ceb/idevice/src/remote_pairing/mod.rs)
