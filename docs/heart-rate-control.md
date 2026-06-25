# Heart-rate → power control: design & research notes

HeartDrive sets a smart trainer's **target power** (ERG mode) to hold the rider's **heart
rate** at a chosen target. Power is the manipulated variable; heart rate is the controlled
variable. This document records how the control loop works, the research behind it, and the
overshoot fixes shipped in Build 23.

The implementation lives in [`HeartDrive/Sources/Control/ErgController.swift`](../HeartDrive/Sources/Control/ErgController.swift).

## The plant (power → heart rate)

Heart rate's response to a step in power is well-modelled as **first-order-plus-dead-time
(FOPDT)**:

| Parameter | Value (cycle ergometer) | Notes |
|---|---|---|
| Steady-state gain | **~0.39–0.46 bpm/W** | Per-rider spread is large: **0.18–0.80 bpm/W** (2–4×). |
| Time constant τ | **~60–69 s** | |
| Dead time θ | **~13–15 s** | Often *omitted* in the literature (models fit to detrended data); explicit fits give 13.1 s treadmill / 13.8 s cycle. |

The plant is also **nonlinear and time-varying**: cardiac drift (a slow ~10–20 bpm upward
creep over 30–60 min at constant power), fitness, fatigue, and an up/down asymmetry (the gain
for a power increase exceeds that for a decrease). The dead-time/time-constant ratio
**θ/τ ≈ 0.25** is firmly **lag-dominant**, which matters for controller choice (below).

The controller carries these as priors (`plantGain 0.39`, `plantTau 60`, `deadTime 15`) and
**learns the per-rider gain online** from the HR response to its own power moves.

## Controller architecture

A slow, integral-dominant **PI controller (no derivative) plus model-based feedforward**:

- **SIMC / lambda (IMC) tuning.** `Kc = (1/Kp)·τ/(λ+θ)`, `Ki = Kc/τ`. The "aggressiveness"
  presets map to the closed-loop time constant λ: Gentle 120 s, Balanced 60 s, Responsive
  30 s (larger λ gives a slower response with more tolerance for model error). SIMC's `Ti = min(τ, 4(λ+θ))` reduces to
  `Ti = τ` for these λ values, so the loop uses `Ti = τ`.
- **Adaptive per-rider plant gain.** The bpm/W slope is learned (EWMA) from settled
  power↔HR "episodes" and clamped to a safe band (Kc within ~0.45–1.4× nominal). Amplifying
  Kc is capped tighter than detuning, since too-high Kc erodes phase margin.
- **Feedforward seeding.** On start and on a target change, the integrator is seeded toward
  the power that holds the target, so the loop starts near the holding power instead of
  integrating up from zero.
- **Safety / robustness.** Output is hard-clamped to `[powerFloor, powerCeiling]` (30%–150%
  of FTP), slew-rate-limited per update, a ±2.5 bpm deadband prevents hunting, and
  back-calculation anti-windup keeps the integral from winding against the floor/ceiling or
  slew limit. The loop ticks every **5 s** (0.2 Hz), matching the cadence of research-grade
  HR compensators.

## The overshoot problem (and root cause)

**Symptom:** even on the gentlest preset, the commanded wattage overshoots the steady-state
holding wattage on start/target-change; HR then overshoots and the loop backs power down.

Root-cause analysis (ranked by contribution):

1. **The feedforward seed targeted the wrong operating point: dominant cause.** The old seed
   was `startingPower(50% FTP) + 0.7·(target − currentHR)/gain`. It was anchored to a fixed fraction
   of FTP plus a slice of the *instantaneous* HR error, **not** the steady-state power that
   holds the target. The integrator therefore started off-point and the PI had to drive the
   rest of the way. Because the seed is independent of λ, **detuning to Gentle cannot fix it**. This matched the symptom exactly.
2. **Integral accumulation across the dead time: the amplifier.** For ~15 s (≈3 ticks) after a
   move, HR has not yet responded, so the integrator keeps ramping power; that excess must
   later unwind, carrying HR past target. Back-calculation anti-windup does **not** catch this. It only acts while the output is clamped by the floor/ceiling or slew limit, not while the
   loop is moving freely.
3. **Proportional kick.** With the full error in the proportional term, a start/step jumps the
   command into the slew limiter, a second over-driving path.

Cardiac drift is a separate slow disturbance, not a start or step overshoot; it is handled by
feedback (slowly lowering power), not by the feedforward.

## The fixes (Build 23)

Three additive changes that attack the three mechanisms above, **without changing λ**. All
remain bounded by the floor/ceiling and slew limits.

1. **Seed to a learned steady-state holding power** (attacks #1). The loop now learns the
   operating point: while settled at the target (and off the floor/ceiling), it EWMAs the
   integrator (the de-slewed operating-point bias) and HR into `learnedHoldPower`/`learnedHoldHR`. The seed becomes that holding power, extrapolated to a
   new target by the learned slope (`P_hold + (target − HR_hold)/gain`). Before any point is
   learned this session, it falls back to the damped cold-start seed. So the integrator lands
   *on* the holding power and the PI only trims a few watts. (The operating point currently
   resets each session; see Future work for cross-session persistence.)
2. **Setpoint ramp / reference shaping** (attacks #3). An internal setpoint ramps first-order
   (τ = 25 s) from the current HR toward the target, and the P and I terms act on this *shaped*
   error. A start or target change no longer presents a step, so there is no proportional kick
   and the loop approaches steady state from a moving reference. (We use a ramp rather than
   `b·SP` setpoint weighting because absolute HR values, ~130–150 bpm, break the
   weighted-setpoint formula: `0.5·target` falls below the current HR.) Learning and gain
   estimation still use the *true* error.
3. **Conditional integration** (attacks #2). The integrator is frozen for one dead-time window
   (`config.deadTime`) after every start/target-change, so it cannot accumulate before HR has
   had a chance to respond. The seed + proportional drive the initial response; integration
   resumes afterward to trim residual offset.

At steady state `internalSetpoint = target`, the shaped error is zero, the proportional term
is zero, and `integral = holding power`, so the seed and the learned value are mutually
consistent.

## What we deliberately did *not* do

- **Smith predictor / dead-time compensation.** The obvious answer for dead time, but it only
  pays off at **θ/τ ≈ 1–2.3** (dead-time-dominant). Our plant is lag-dominant (θ/τ ≈ 0.25),
  where plain SIMC tuning is sufficient, and the Smith predictor is
  **fragile to model mismatch** (can perform *worse than plain PI* under ±50% dead-time error),
  which is dangerous on a rider-varying, time-varying plant. If dead-time compensation ever
  becomes necessary, use a *filtered* Smith predictor / dead-time-compensated PID with explicit
  gain (×3) and dead-time margins.
- **Model Predictive Control.** Computationally feasible at 0.2 Hz, and it handles dead time and
  move-rate constraints natively, but on an *uncertain* plant a well-tuned PID + anti-windup is
  competitive with MPC, and MPC would largely re-derive what fixes #1–#3 already give. Deferred.
- **Gain scheduling / H-infinity.** HR dynamics are largely intensity-independent across the
  aerobic band, so scheduling buys little; H-infinity is what the Hunt group uses for its
  H-infinity controller, but adopting it would replace the current controller and would not
  address start or step overshoot. The current PI controller retains its SIMC tuning.

## What the HR-exercise-control literature achieves

- Best demonstrated tracking is **RMS error ≈ 2.0–3.1 bpm** (treadmill and cycle), dipping just
  under 2 bpm in the best cases. **The cited studies don't report overshoot or settling time.**
  the field's metrics are RMS tracking error and control-signal power. A sensible internal goal
  is therefore *no power overshoot at RMS ≈ 2.5 bpm*.
- Linear ≈ nonlinear for control (nonlinear is even worse at low intensity); a second-order
  compensator beat first-order by a small but significant ~7% (1.98 vs 2.13 bpm).

## Tuning knobs

| Knob | Where | Effect |
|---|---|---|
| `setpointTau` (25 s) | `ErgController` | Larger = gentler approach, less overshoot, slower to reach target. |
| `integralFreezeRemaining` window = `deadTime` (15 s) | `ErgController` | Longer freeze = less dead-time wind-up, slower trim. |
| `holdLearnRate` (0.05/tick) | `ErgController` | EWMA weight for the learned operating point. |
| `feedforwardFraction` (0.7) | `ErgControllerConfig` | Cold-start damping only (before a holding point is learned). |
| `lambda` per preset (120/60/30 s) | `ControlAggressiveness` | Closed-loop speed vs. robustness. |

## Future work

- **Cross-session persistence of the learned operating point** (`learnedHoldPower`/`HR`), so the
  *first* ride of each session also seeds onto the holding power instead of cold-starting. The
  biggest remaining win; needs plumbing through `AppModel`/`SettingsStore`.
- **HR-reserve cold-start.** Seed the first ride from `%HRR ≈ %VO₂R → fraction of FTP` instead of
  a flat 50% FTP; this requires the rider's HRmax/HRrest as settings.
- **Forgetting-factor RLS** for the operating-point/gain estimates, to track drift and fatigue
  more principledly than a fixed EWMA.

## Sources

Peer-reviewed (HR-exercise control & physiology):
- Hunt & Fankhauser, robust HR control for cycle ergometer: https://pmc.ncbi.nlm.nih.gov/articles/PMC6828638/
- Spörri/Wang/Hunt, 1st vs 2nd-order cycle HR control: https://www.frontiersin.org/journals/control-engineering/articles/10.3389/fcteg.2022.894180/full
- Hunt et al., treadmill HR dynamics (intensity-independence, asymmetry): https://pmc.ncbi.nlm.nih.gov/articles/PMC4687158/
- Hunt et al., role of model zeros and dead time (explicit FOPDT fits): https://pmc.ncbi.nlm.nih.gov/articles/PMC11550391/
- Wang & Hunt, two-phase treadmill HR control: https://pmc.ncbi.nlm.nih.gov/articles/PMC10593204/
- Su et al., nonparametric Hammerstein MPC for treadmill HR: https://pubmed.ncbi.nlm.nih.gov/18002622/
- Paradiso/Verrelli, nonlinear PI HR regulation (cycle): https://pubmed.ncbi.nlm.nih.gov/23086500/
- Swain & Leutholtz, %HRR ≈ %VO₂R: https://pmc.ncbi.nlm.nih.gov/articles/PMC3861769/
- Coyle & González-Alonso, cardiovascular drift: https://pubmed.ncbi.nlm.nih.gov/11337829/

Control theory:
- Skogestad, SIMC tuning rules: https://skoge.folk.ntnu.no/publications/2003/tuningPID/README.html
- Normey-Rico et al., PID vs advanced control for dead-time systems: https://www.sciencedirect.com/science/article/abs/pii/S0019057819304239
- Anti-windup in PID control: review & tuning: https://arxiv.org/html/2606.01959v1
- Setpoint filter design to minimize overshoot (ISA Transactions): https://www.sciencedirect.com/science/article/abs/pii/S0019057811001212

Practitioner (authoritative):
- MathWorks: 2-DOF/setpoint weighting, Smith predictor, anti-windup, MPC horizons: https://www.mathworks.com/help/control/ug/two-degree-of-freedom-2-dof-pid-controllers.html
- OptiControls: lambda tuning; dead-time-dominant thresholds (`td > 2τ`): https://blog.opticontrols.com/tuning-rules-for-dead-time-dominated-processes/
- Control Global: setpoint-response tips; Smith predictor vs deadtime-compensated PID face-off: https://www.controlglobal.com/control/loop-control/article/55264206/face-off-smith-predictor-vs-deadtime-compensated-pid
