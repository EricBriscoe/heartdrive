# HeartDrive

Hold your heart rate at a target while you ride in Zwift, by automatically
adjusting your Wahoo KICKR Core's resistance. It's cruise control for heart
rate: HeartDrive reads heart rate from your Apple Watch or a Bluetooth monitor and
runs the trainer in ERG mode, raising power when your HR is below target and easing off
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
     │  Step-and-wait control: HR band ──► target watts
     ▼
  KICKR Core ◄──FTMS ERG (Bluetooth)── set target power
     ▲
     └──Bluetooth (read-only: Power + Cadence)── Zwift (on Apple TV / PC / iPad)
```

- The **watch app** runs an indoor-cycling `HKWorkoutSession` (this is what
  raises the HR sample rate and keeps the watch app alive with the screen off)
  and sends heart rate through **WatchConnectivity**. Live messages use replies to
  confirm delivery. A coalesced application context provides a rate-limited backstop.
  The watch requests recovery when capture or reachable delivery stalls.
- A **Bluetooth heart-rate monitor** can replace the watch as the HR source.
  Select it in Settings. The phone reads the standard GATT Heart Rate Service.
- The **phone app** owns the trainer over Bluetooth and runs a conservative
  **step-and-wait controller** that keeps HR near an adjustable target by making
  small ERG power changes via the standard **FTMS** control point
  (with a Wahoo-proprietary fallback).
- **Zwift** connects to the same trainer *read-only* for the visuals and ride
  recording. The KICKR Core supports up to 3 simultaneous Bluetooth links, so
  this coexistence is its intended use case.

---

## Requirements

- **Wahoo KICKR Core** (or any FTMS-capable smart trainer). Firmware **≥ v1.0.11**
  for multi-connection; **≥ v1.3.17** adds auto-calibration. Update via the
  Wahoo app.
- **iPhone** on iOS 17+, plus either a paired **Apple Watch** on watchOS 10+ or a Bluetooth HR monitor.
- **A second device to run Zwift**: Apple TV, PC/Mac, or iPad. *(See the
  important note below. This isn't optional for the same-trainer setup.)*
- **Xcode 26+** to build from source. TestFlight distribution requires a paid Apple Developer membership.

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
2. Signing is preset to team `WJPH3B5Z5U`. If Xcode asks,
   pick your team for both the `HeartDrive` and `HeartDriveWatch` targets. If the
   bundle ID `com.ericbriscoe.HeartDrive` is taken on your account, change the
   prefix in `project.yml` and re-run `xcodegen generate`.
3. **Build & Run** (⌘R). The watch app installs alongside it; if it doesn't
   appear, install it from the Watch app on your iPhone.

### Checks and cleanup tools

```bash
brew install periphery swiftlint
./scripts/check.sh             # control, core, link tests; both targets; focused lint
./scripts/check.sh --analyze   # also build/index both targets and report code clones
```

The analyzer pass also requires Node.js/npm and XcodeGen. It pins jscpd to 4.0.8.
Verified versions: Periphery 3.8.0 and SwiftLint 0.65.1.
Periphery's original open-source repository is archived. Check compatibility before upgrading Xcode or adopting a different Periphery distribution.

`Tools/CoreTests` covers BLE packet boundaries, HR freshness, synchronization and link recovery with deterministic seeds.
[LinkSim](Tools/LinkSim/README.md) drives the production link policy and HR receiver under simulated transport failures.
Clone reports go to a temporary directory. They identify review candidates, not automatic deletions.

The HeartDrive scheme includes picker UI tests. Run them on a disposable simulator:

```bash
xcodebuild test -project HeartDrive.xcodeproj -scheme HeartDrive \
  -destination 'platform=iOS Simulator,id=<simulator-uuid>' CODE_SIGNING_ALLOWED=NO
```

The UI tests change simulator settings. Bluetooth, HealthKit capture and screen-off recovery still require real devices.
Free Personal Team builds expire after about seven days and cannot use TestFlight.

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
5. Bump `CURRENT_PROJECT_VERSION` in `project.yml` for every new upload.

For the existing app, the release script runs checks, regenerates the project, and archives both apps:

```bash
ASC_KEY_ID=<key-id> ASC_ISSUER_ID=<issuer-id> ./scripts/release.sh
```

Keep `AuthKey_<key-id>.p8` in `~/.appstoreconnect/private_keys/`, never in this repository.
Without credentials, the script exports an IPA without uploading it.
An upload receipt is not TestFlight availability. Confirm processing and tester-group access in App Store Connect.

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
2. **HR source:** use the watch, or select Bluetooth in Settings and connect your monitor.
   For the watch, grant HealthKit access and start a workout.
3. **Set your target HR** right on the main screen with the big **− / +** buttons
   (adjust it any time, mid-ride). Set FTP under the **gear icon**; starting watts
   and power bounds are derived from it.
4. **Zwift:** start your ride on the other device (paired as above).
5. **Start:** tap **Start heart-rate control** on the phone (or **Start** on the
   watch). HeartDrive warms up for two minutes, then adjusts watts toward your HR band.

The dashboard shows your HR vs. target, the trainer's actual power, the target
power the loop is commanding, cadence/speed, and a status line
(*Warming up / Following HR / At ceiling / Heart rate lost / Paused*).

The phone **stays awake** automatically while controlling or broadcasting, so
auto-lock can't drop the watch link or the Zwift broadcast. Keep HeartDrive in
the foreground during the ride (Zwift is on your other device).

## Show your heart rate in Zwift

Flip **"Broadcast HR to Zwift"** on the dashboard and the phone re-advertises your
selected source's heart rate as a standard Bluetooth Heart Rate sensor. In Zwift's pairing
screen, pair **"HeartDrive"** under **Heart Rate**; your live pulse now shows
in-game, no chest strap needed. This runs alongside trainer control (the phone is
a Bluetooth *central* to the KICKR and a *peripheral* for HR at the same time).
The status line under the toggle shows *Advertising* → *Connected to 1 app, sending N bpm*.

**Using a Bluetooth chest strap (e.g. Polar H10) instead of the watch?** Zwift
remembers its last heart-rate sensor and auto-pairs it. If you ever paired the
strap in Zwift directly, it will keep hunting for the strap, which HeartDrive
already holds (a stock H10 accepts one Bluetooth connection), and Zwift will never
pick "HeartDrive". In Zwift's pairing screen, unpair the strap and pair
**"HeartDrive"** instead. The same one-connection rule means the strap must not be
added to your Apple Watch as a Health Device or open in the Polar app while you ride.

---

## The control loop

Heart rate responds slowly to power changes. For steady Zone 2 rides, HeartDrive
uses small steps and waits rather than predicting a rider's HR response.

- **Target ±3 BPM:** hold watts inside the band.
- **Two-minute warm-up:** start at 50% FTP; no increases, but reductions are allowed.
- **Small adjustments:** after 15 seconds outside the band, change by ±5 W,
  with at least 30 seconds between normal adjustments.
- **Sustained excess HR:** at least 10 BPM above target for 15 seconds reduces power
  by 10 W, at most once every 15 seconds.
- **Hard bounds:** every command respects the FTP-derived floor and ceiling.
- **Signal loss/coasting:** hold briefly, then reduce toward the floor. Recovery
  never jumps back to starting watts. Stale HR and telemetry cannot drive increases.

The HR target stays adjustable on the phone and watch. There is no Responsiveness
setting or learned rider model. Select your own appropriate training HR; the app
cannot determine physiological Zone 2. These safeguards are not medical protection.

See [the control policy and validation checklist](docs/heart-rate-control.md).
Run deterministic checks with `bash scripts/test-control.sh`.

---

## Project layout

```
project.yml                     XcodeGen spec (iOS app + embedded watchOS app)
scripts/check.sh                Tests, type-checks, lint and optional analysis
scripts/release.sh              Verified archive/export and optional TestFlight upload
Shared/
  WatchMessages.swift           Portable message types and last-write-wins registers
  WatchSession.swift            WatchConnectivity keys, serialization and logging
  HeartRateLink.swift           Watch sender timing and recovery policy
HeartDrive/                     iOS app
  Sources/App/                  HeartDriveApp, AppModel (coordinator + control tick)
  Sources/Bluetooth/            FTMS protocol, control strategies, CoreBluetooth manager
  Sources/Control/              ErgController (step-and-wait HR control)
  Sources/HeartRate/            HeartRateHub (EWMA + freshness)
  Sources/Connectivity/         PhoneConnectivity (WatchConnectivity)
  Sources/Models/               RideSettings + persistence
  Sources/Views/                SwiftUI dashboard, settings, trainer picker
HeartDriveWatch/                watchOS app
  Sources/                      Workout manager (HealthKit), connectivity, UI
```

---

## Limitations & possible next steps

- Supported HR sources are Apple Watch and standard Bluetooth HR monitors.
  AirPods/Powerbeats HealthKit HR capture is not implemented.
- WatchConnectivity recovery depends on device and OS behavior. Simulation does not guarantee uninterrupted screen-off delivery.
- **Same-device Zwift** (Zwift + HeartDrive on one iPhone) is intentionally not
  supported. See the critical note above. A trainer-bridge (emulating a fake
  trainer to Zwift) would be required and is a much larger project.
- No ride-history UI. Watch workouts use HealthKit. Diagnostic `control-*.csv` files are available through Finder/Files.

---

*Built for personal use. "KICKR" and "Wahoo" are trademarks of Wahoo Fitness;
"Zwift" of Zwift Inc. This project is not affiliated with either.*
