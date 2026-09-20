# Heart-rate control

HeartDrive targets steady endurance rides, not exact beat-by-beat tracking or short intervals.
The rider selects a target HR. The controller aims for target ±3 BPM. The rider must choose
an appropriate training range; the app does not determine physiological Zone 2.

## Step-and-wait policy

- Evaluate lightly smoothed, fresh HR every 5 seconds.
- Start at 50% of configured FTP. Count 120 seconds of valid HR and pedaling as warm-up.
  No increases during warm-up; reductions remain enabled.
- Inside the inclusive ±3 BPM band: hold watts.
- Outside the band for 15 seconds: change by +5 W below or −5 W above,
  provided at least 30 seconds have elapsed since the last adjustment.
- At least 10 BPM above target for 15 seconds: reduce by 10 W, with at least
  15 seconds between these reductions. This also applies during warm-up.
- Reset persistence after a step, a direction change, target edit, or missing input.
- Target edits retain current watts and restart the wait; they do not restart warm-up.
- A delayed timer callback earns at most 5 seconds of observation credit and never
  causes multiple catch-up steps.

There is no integral, HR–power model, gain estimation, learned holding power, or
Responsiveness setting. Old saved settings still decode; the removed field is ignored.

## Guards

- Final commands always obey the power bounds, including after a setting change or
  on a dropout path. Bounds remain 30%–150% of FTP. FTP also sets starting watts.
- Missing HR: hold for less than 20 seconds, then reduce 10 W per normal tick to the floor.
- Missing pedaling: hold for less than 8 seconds, then reduce at the same rate.
- On recovery, keep the reduced watts and restart the adjustment wait. Do not jump
  back to starting power. Warm-up pauses while input is missing.
- Trainer disconnection, unavailable control, control conflict, and stale cadence/power
  suppress upward control. Do not write while disconnected or a conflict is active.
- HR must be finite, 30–230 BPM, and measured less than 12 seconds ago, allowing
  up to 2 seconds of clock skew. Reject duplicates and reordered samples within a source.
- Stable BPM with advancing timestamps is valid. Source changes or recovery after a
  stale period reset smoothing. Stale timestamp high-water marks expire.
- Pedaling requires cadence or power telemetry less than 12 seconds old. Fresh cadence
  takes precedence over power. Missing telemetry is not treated as pedaling.

The floor is not zero resistance, and these are operational safeguards, not medical
protection. Stop the ride if unwell. Keep Zwift's Controllable pairing empty.

## Validation

Run `bash scripts/test-control.sh` for deterministic controller, HR freshness, and
legacy-settings checks. Run `zsh scripts/typecheck.sh` for iOS/watchOS type checks.
The existing `Tools/LinkSim` suite covers phone/watch synchronization separately.

Before relying on a new build, verify on a trainer: warm-up, slow approach to target,
20-minute steady riding, target changes, coasting/resume, HR disconnection/recovery,
and another app attempting trainer control. Review the control CSV for overshoot,
time in band, and power oscillation. Default timings are engineering starting points,
not rider-validated physiological constants.
