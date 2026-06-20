# HeartDrive

Hold your heart rate at a target while you ride in Zwift, by automatically
adjusting your Wahoo KICKR Core's resistance. It's cruise control for heart
rate: HeartDrive reads your live heart rate from your Apple Watch and runs the
trainer in ERG mode, raising power when your HR is below target and easing off
when it's above, so Zwift becomes the scenery while your body does exactly the
effort you asked for.

This is the open-source HR→power loop that the big platforms don't ship: Zwift,
Wahoo SYSTM, Rouvy, etc. all treat heart rate as display-only.

---

## How it works

```
Apple Watch ──HKWorkoutSession──► live HR
     │  (WatchConnectivity)
     ▼
  iPhone (HeartDrive)
     │  PI control loop: HR error ──► target watts
     ▼
  KICKR Core ◄──FTMS ERG (Bluetooth)── set target power
     ▲
     └──Bluetooth (read-only: Power + Cadence)── Zwift (on Apple TV / PC / iPad)
```

- The **watch app** runs an indoor-cycling `HKWorkoutSession` (this is what
  raises the HR sample rate and keeps the watch app alive with the screen off)
  and streams heart rate to the phone over **HealthKit workout-session
  mirroring** is reliable in the background and screen-off, where the older
  WatchConnectivity path stalled (WCSession is kept only as a fallback).
- The **phone app** owns the trainer over Bluetooth and runs a slow, heavily
  damped **PI controller** that converts heart-rate error into an ERG target
  power, then writes it to the KICKR via the standard **FTMS** control point
  (with a Wahoo-proprietary fallback).
- **Zwift** connects to the same trainer *read-only* for the visuals and ride
  recording. The KICKR Core supports up to 3 simultaneous Bluetooth links, so
  this coexistence is its intended use case.

---

## Requirements

- **Wahoo KICKR Core** (or any FTMS-capable smart trainer). Firmware **≥ v1.0.11**
  for multi-connection; **≥ v1.3.17** adds auto-calibration. Update via the
  Wahoo app.
- **iPhone** on iOS 17+ and **Apple Watch** on watchOS 10+ (paired).
- **A second device to run Zwift**: Apple TV, PC/Mac, or iPad. *(See the
  important note below. This isn't optional for the same-trainer setup.)*
- **Xcode 26+** to build and install (this is a source project, not an App Store app).

---

## Build & install

This project is defined with [XcodeGen](https://github.com/yonaskolb/XcodeGen);
the `.xcodeproj` is generated, not committed.

```bash
brew install xcodegen        # once
cd heartdrive
xcodegen generate            # produces HeartDrive.xcodeproj
open HeartDrive.xcodeproj
```

In Xcode:

1. Select the **HeartDrive** scheme and your connected **iPhone** as the destination.
2. Signing is preset to the free **Personal Team** (`WJPH3B5Z5U`). If Xcode asks,
   pick your team for both the `HeartDrive` and `HeartDriveWatch` targets. If the
   bundle ID `com.ericbriscoe.HeartDrive` is taken on your account, change the
   prefix in `project.yml` and re-run `xcodegen generate`.
3. **Build & Run** (⌘R). The watch app installs alongside it; if it doesn't
   appear, install it from the Watch app on your iPhone.

> **Type-check without building** (handy while editing): `./scripts/typecheck.sh`
> compiles both targets against the SDKs directly. The iOS Simulator is unusable
> on this machine (CoreSimulator version skew), but that doesn't matter here,
> because Bluetooth and HealthKit only work on real hardware anyway.

### Free Apple Developer account caveats

You're using a free Personal Team, so:

- **The app stops launching ~7 days after each install.** Reconnect your iPhone
  to Xcode and Run again to re-sign for another week. A paid Apple Developer
  account ($99/yr) removes this.
- HealthKit and background Bluetooth work for on-device development on a free
  account; you just can't distribute through the App Store.

---

## Putting it on TestFlight

TestFlight requires a **paid Apple Developer Program** membership ($99/yr); the
free Personal Team can't use App Store Connect. Once enrolled:

1. Point both targets at your paid team: set `DEVELOPMENT_TEAM` in `project.yml`,
   run `xcodegen generate` (or let Xcode prompt for the team).
2. In **App Store Connect**, create the app with bundle id `com.ericbriscoe.HeartDrive`,
   plus a globally-unique app name.
3. In Xcode, select **Any iOS Device**, then **Product ▸ Archive ▸ Distribute App ▸
   App Store Connect ▸ Upload**. The watchOS app goes up inside the iOS app.
4. After it processes (~10 min), add testers under the **TestFlight** tab. Internal
   testers (your App Store Connect team) need no review; external testers need a
   one-time Beta App Review and a **privacy policy URL** (required for HealthKit apps).
5. Bump `CURRENT_PROJECT_VERSION` for every new upload.

Already handled: the app icon (generated with fal.ai Recraft, `app-icon.svg`), the
launch screen, and `ITSAppUsesNonExemptEncryption = false` (skips the per-build
export-compliance prompt).

## ⚠️ The one critical setup detail: run Zwift on a *separate* device

A Bluetooth trainer accepts **control** commands from **one** source at a time,
and iOS won't reliably let HeartDrive control the trainer while Zwift also uses
it **on the same iPhone**. So:

- **Run Zwift on Apple TV, a PC/Mac, or an iPad**, not the same iPhone as HeartDrive.
- In **Zwift's pairing screen**, pair the KICKR as:
  - **Power Source** ✅
  - **Cadence** ✅
  - **Controllable** ❌ **Leave this EMPTY.**
- Leaving *Controllable* empty is what guarantees Zwift never fights HeartDrive
  for resistance. (Power/Cadence are read-only Bluetooth subscriptions. "Look
  but don't touch.")

If you pair the KICKR as *Controllable* in Zwift, the two apps will send
conflicting resistance commands and the ride will feel erratic. HeartDrive
watches the trainer's FTMS status events and **flashes a red warning** if it
detects another app controlling the trainer (simulation-parameters-changed,
control-permission-lost, or a target-power change it didn't command), so you'll
know to clear the Controllable slot. The warning clears itself a few seconds
after the other app stops.

---

## Using it

1. **Trainer:** open HeartDrive on the iPhone, tap the antenna icon, and connect
   your KICKR (pedal a turn first to wake it). Wait for **"Trainer · FTMS"** (green).
2. **Watch:** open HeartDrive on your Apple Watch, grant HealthKit access on
   first launch, and it will begin reading HR.
3. **Set your target HR** right on the main screen with the big **− / +** buttons
   (adjust it any time, mid-ride). Floor/ceiling and responsiveness live under the
   **gear icon**; the ceiling is your main safety limit.
4. **Zwift:** start your ride on the other device (paired as above).
5. **Start:** tap **Start heart-rate control** on the phone (or **Start** on the
   watch). HeartDrive now holds your heart rate at target.

The dashboard shows your HR vs. target, the trainer's actual power, the target
power the loop is commanding, cadence/speed, and a status line
(*Settling / Holding target / At ceiling / Heart rate lost / Paused*).

The phone **stays awake** automatically while controlling or broadcasting, so
auto-lock can't drop the watch link or the Zwift broadcast. Keep HeartDrive in
the foreground during the ride (Zwift is on your other device).

## Show your heart rate in Zwift

Flip **"Broadcast HR to Zwift"** on the dashboard and the phone re-advertises your
watch's heart rate as a standard Bluetooth Heart Rate sensor. In Zwift's pairing
screen, pair **"HeartDrive"** under **Heart Rate**; your live pulse now shows
in-game, no chest strap needed. This runs alongside trainer control (the phone is
a Bluetooth *central* to the KICKR and a *peripheral* for HR at the same time).
The status line under the toggle shows *Advertising* → *Connected to Zwift*.

---

## The control loop

Heart rate responds slowly to a power change (~15 s of dead time, ~60 s time
constant), so a naive controller oscillates. HeartDrive uses a deliberately
slow, integral-dominant design (derived from published cycle-ergometer HR
control research):

- **PI controller, no derivative**, updated every **5 s** on an EWMA-smoothed HR.
- **±2.5 bpm deadband** so it doesn't chase noise.
- **Ramp-limited** to ±5 W up / ±10 W down per update (down faster, so it backs
  off promptly if your HR spikes).
- **Power clamped** to your floor/ceiling, with anti-windup (conditional
  integration + back-calculation) so the integral doesn't overshoot at the limits.
- **Cardiac drift** (HR creeping up over a long ride) is handled by the integral term, which slowly lowers target power to keep you on target.

**Safety guards:**

- **Stop pedaling → resistance releases.** ERG mode would otherwise ramp
  resistance toward infinity (the "spiral of death") when cadence hits zero;
  HeartDrive freezes the controller and drops the trainer to the power floor
  until you pedal again.
- **HR dropout** → holds the last power briefly, then bleeds down toward the
  floor rather than holding a high effort blind.

The **Responsiveness** setting maps to the loop's closed-loop time constant
(λ): *Gentle* is the smoothest/most stable, *Responsive* is quicker but still
damped. If you ever see the resistance hunting up and down, choose a gentler
setting.

---

## Project layout

```
project.yml                     XcodeGen spec (iOS app + embedded watchOS app)
scripts/typecheck.sh            Type-check both targets without the simulator
Shared/
  WatchMessages.swift           Codable phone↔watch message envelope
HeartDrive/                     iOS app
  Sources/App/                  HeartDriveApp, AppModel (coordinator + control tick)
  Sources/Bluetooth/            FTMS protocol, control strategies, CoreBluetooth manager
  Sources/Control/              ErgController (the PI loop)
  Sources/HeartRate/            HeartRateHub (EWMA + freshness)
  Sources/Connectivity/         PhoneConnectivity (WatchConnectivity)
  Sources/Models/               RideSettings + persistence
  Sources/Views/                SwiftUI dashboard, settings, trainer picker
HeartDriveWatch/                watchOS app
  Sources/                      Workout manager (HealthKit), connectivity, UI
```

---

## Limitations & possible next steps

- **Heart-rate source is the Apple Watch only.** The HR input is abstracted
  (`HeartRateHub`), so adding a BLE chest strap (`0x180D`, the most accurate and
  reliable source) or AirPods Pro 3 / Powerbeats Pro 2 HR (HealthKit, iOS 26+)
  would require another `HeartRateHub` source.
- **Watch→phone HR uses HealthKit workout-session mirroring** (with WatchConnectivity
  as a fallback), so it survives the watch screen turning off during a ride.
- **Same-device Zwift** (Zwift + HeartDrive on one iPhone) is intentionally not
  supported. See the critical note above. A trainer-bridge (emulating a fake
  trainer to Zwift) would be required and is a much larger project.
- No ride history or export yet; the workout is recorded by HealthKit on the watch.

---

*Built for personal use. "KICKR" and "Wahoo" are trademarks of Wahoo Fitness;
"Zwift" of Zwift Inc. This project is not affiliated with either.*
