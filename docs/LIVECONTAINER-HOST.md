# Apple TV developer setup inside LiveContainer + SideStore

The requested outcome is to establish developer access on an Apple TV that has
not already been set up with Xcode, using TVPair inside the combined host.
The current TVPair releases have not established that outcome on physical tvOS.
The earlier guide/result-display changes did not implement or prove activation.

Two prerequisites are separate:

1. The phone must be allowed to discover the developer-pairing service. The
   supplied `-72008` comes from the phone's Bonjour configuration. Changing
   the TV's developer state cannot fix that local error. The installed host
   must declare `_remotepairing-manual-pairing._tcp` and `_remoted._tcp`.
2. The TV must accept a developer pairing exchange and its displayed code.
   A TCP connection or AirPlay/Companion advertisement is not that exchange.
   No pre-pair activation request has been verified for this tvOS 27.2 device.

The AMFI `action: 1` enable operation in existing tools is reached through a
lockdown service (or its authenticated RSD shim). It is not an unauthenticated
bootstrap command to send to AirPlay/Companion. Apple's terminology that tvOS
has no separate Developer Mode switch does not by itself implement Xcode's
developer setup behavior. Legacy CU pairing also has a developer ACL, but
those lockdown CU messages must not be mixed into RPPairing without evidence.

The outbound RPPairing host model has been corrected from `iPhone` to the
reference clients' `computer-model` role. This fixes a reference mismatch, but
cannot affect a browser that is rejected before any request is sent or prove
that Developer Settings will appear on the TV.

## Matching host preparation

The user identified customized SideStore-integrated **3.8.11-Release**, with
LiveContainer commit `009d697720aa968fff35f0d36b280b36b18bfb95` and embedded
SideStore `0.7.0-20261017.511+ee3cc16a`. A matching combined artifact was found
in the user's LiveContainer-selfjit repository, run **41339975629**. The
screenshots' personal signing identifiers are not copied into this document.
Do not substitute the latest stable/nightly or another fork.

`scripts/prepare-livecontainer-host.py` prepares a new copy of the selected
combined IPA. It requires an explicit source hash and expected version,
preserves existing declarations, adds TVPair's service names, and changes only
the top-level app's Info.plist. It verifies all other entries byte-for-byte,
including embedded SideStore and frameworks. It does not sign, install,
refresh, clear data, or change identifiers. Existing signatures are no longer
valid after the metadata change; the copy must be re-signed through the user's
host installation method under the existing identity. Replacing an installed
host is not performed by the helper.

The helper's syntax compiled with a portable Python 3.13 runtime obtained
from Python.org and checked against the official Sigstore bundle's digest.
Package preservation and actual phone/TV behavior require separate checks;
helper syntax validation is not evidence of working developer activation.

## References

- [Apple: Developer Mode and tvOS developer settings](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
- [Apple: missing Bonjour configuration](https://developer.apple.com/documentation/foundation/netservice/errorcode-swift.enum/missingrequiredconfigurationerror?language=objc)
- [LiveContainer host declarations](https://github.com/LiveContainer/LiveContainer/blob/9d6ea09b05afa2c8fc537c372795a294db631311/LiveContainer/Info.plist)
- [idevice RPPairing computer host identity](https://github.com/jkcoxson/idevice/blob/89702099f4d7552f704f93b4526756abda319ceb/idevice/src/remote_pairing/mod.rs)
- [pymobiledevice3 AMFI service](https://github.com/doronz88/pymobiledevice3/blob/776d601cec83b894c3ad0eeee8ab4db375a46e4a/pymobiledevice3/services/amfi.py)
- [libimobiledevice CU pairing contract](https://github.com/libimobiledevice/libimobiledevice/blob/master/include/libimobiledevice/lockdown.h)
