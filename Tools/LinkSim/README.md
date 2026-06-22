# LinkSim: reproducing and testing the watch↔phone HR connection

A deterministic, dependency-free simulator that **reproduces** the heart-rate feed
flakiness we hit on real hardware and **proves** the resilient wrapper that fixes it.
Real Apple Watch ⇄ iPhone flakiness can't be run in a loop, so we model the documented
WCSession failure modes as an injectable transport and assert the wrapper survives them.

```
swift run --package-path Tools/LinkSim
```

## What it reproduces

`Mock.swift`'s `FlakyTransport` injects every failure mode that bit us:

- **Context wedge**: driving `updateApplicationContext` faster than ~1/5s silently
  wedges delivery (rdar://21364664). This is the original "works, then stalls" bug.
- **Reachability flapping / stuck-false**: `sendMessage` only works while reachable, and
  the watch screen-off bug can report `isReachable == false` for a whole ride.
- **Transient `sendMessage` failures** even while reachable.
- **Total blackout**: neither path delivers (models a hard wedge / reboot-only).
- **HR capture stall**: the watch stops producing samples.
- **Bursts**: `HKLiveWorkoutBuilder` delivers HR in sub-second bursts.

Scenario 2 runs the *old* behavior (over-driven context, no self-heal) and reproduces a
**106-second permanent stall**: exactly the on-device symptom.

## What it proves

`Link.swift`'s `HeartRateSender` is the resilient wrapper (mirrored in the app's
`HeartDriveWatch/Sources/WatchConnectivityManager.swift`). It:

- sends live HR over `sendMessage` when reachable (throttled), with a coalescing
  `updateApplicationContext` backstop **held to ≤1/5s** so it can never wedge the channel;
- keeps re-sending the latest value, so a dropped/coalesced send self-heals next cycle;
- **self-heals**: re-activates the session on a sustained delivery gap, and asks the owner
  to restart the workout if delivery (or HR capture) stays dead; it does not restart for mere
  unreachability (the context backstop covers that).

The 24-check suite, including combined chaos and a **300-run randomized fuzz**, finds
**zero permanent stalls**, worst-case staleness **5.8s** (well under the 12s control
threshold). The harness is the spec: keep it and `WatchConnectivityManager` in sync.
