# LinkSim

Deterministic watch-to-phone transport tests. Run from the repository root:

```bash
./scripts/test-link.sh
```

The script compiles the production `Shared/HeartRateLink.swift`, message types and
`HeartRateHub` directly. No copied sender or receiver policy remains in this tool.
`Link.swift` only connects the policy to a fake transport and clock.

## Simulated failures

- Context delivery wedges when updates exceed the modeled channel limit.
- Reachability changes or remains false.
- Live messages fail or receive delayed replies.
- Both transport paths stop during a blackout.
- HR capture stops, resumes or delivers bursts.

The historical-failure scenario disables healing and removes the context throttle.
It must reproduce a long stall. The production configuration must recover in the
same model without restarting merely because the live path is unreachable.

The suite includes 300 seeded adversaries. Failures print their seeds for replay.
`Tools/CoreTests` separately covers timestamp rollback, stream reset, stale replies,
settings-only context, and exact timing boundaries.

These checks verify behavior under the model, not Apple's implementation.
Use a paired watch and phone to verify real Bluetooth, HealthKit and screen-off recovery.
