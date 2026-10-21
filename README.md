# Moth

Moth is an iPhone app that measures light flicker with the camera. You can use it to find rooms where the lighting is hard on sensory-sensitive people, such as people with migraine, photosensitive epilepsy, or eye strain. Most flicker is too fast to see, but the camera's rolling shutter can pick it up. Moth reads the brightness of each image row, which gives it a timing resolution well beyond the frame rate, and grades the result against the **IEEE 1789-2015** guideline.

Everything stays on the device. Moth has no accounts, no backend and no networking.

## What it does

- **Measure.** Point the top of the phone at a light and hold still for a few seconds. Moth then reports:
  - a plain-language verdict: *Looks good*, *Mild flicker* or *Strong flicker*
  - the flicker frequency (Hz) and the modulation depth (%)
  - how far over the IEEE 1789 low-risk limit the light is
  - a confidence level from 1 to 5
  - a reconstructed waveform of the measured signal
- **Fixes.** When a light goes over the limit, Moth suggests accommodations to ask about, such as fixture swaps, filters, PWM driver changes or seating changes. The suggestions differ below and above 90 Hz, and each one cites its source (JAN, DOE, Epilepsy Society, American Migraine Foundation).
- **Rooms and buildings.** You can save a measurement to a room and group rooms by building. Both lists are sorted worst first, so the places that need attention come up first. Each room keeps:
  - its measurement history, with trends and a chart of depth over time
  - an optional 1–5 comfort rating
  - the fixture type, which you enter yourself
  - notes
  - a personal checklist of coping strategies, which can include your own
- **Calibration.** On first launch, Moth runs a one-time calibration against an older fluorescent or incandescent fixture. It uses the known flicker frequency of mains power (100 or 120 Hz) to work out the sensor's line readout time. It captures twice and only accepts the result if the two readings agree.
- **Settings.** You can set the mains region (50 or 60 Hz), switch between light and dark appearance (dark is the default), turn animations on or off, and enable a debug mode. You can also reset the calibration or erase everything. The app opens with onboarding and a terms screen.

## Measurement tiers

What Moth can report depends on what the device can measure reliably. It never shows a number it can't support:

| Tier | Requires | Reports |
|---|---|---|
| 1 — Full measurement | Calibrated, steady exposure | Frequency, depth, IEEE 1789 verdict |
| 2 — Frequency only | Calibrated | Frequency |
| 3 — Presence only | Uncalibrated | Whether flicker is present |

## Project layout

| Target | Role |
|---|---|
| `MeasurementCore` | Models, IEEE 1789 limits, guidance, row-brightness extraction, periodogram analysis and calibration solver. Uses no UI or AVFoundation. |
| `MothCapture` | AVFoundation capture with locked exposure, permissions, device identity and the measurement runner |
| `MothPersistence` | SwiftData store with versioned schema migrations, plus user settings |
| `MothUI` | SwiftUI screens: Measure, Rooms, Buildings, Settings, Calibration and Onboarding |
| `Moth/` | App entry point (`MothApp`) |

## Building

Requires Xcode with Swift 6 and iOS 18 or later. A physical iPhone is needed to measure, because the simulator has no camera.

- **App:** open `Moth.xcodeproj` and run the `Moth` scheme on a device.
- **Tests:** the packages also build on macOS, so you can run the tests without a device:

  ```sh
  bash Scripts/swiftpm.sh test
  ```

## Disclaimer

Moth is a benchmarking tool, not a certified or professional flicker meter. Its results are estimates for reference only. They are not medical, safety or compliance advice.
