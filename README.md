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
- **Calibration.** On first launch, Moth runs a one-time calibration against an older fluorescent or incandescent fixture. It takes about twenty seconds and has two parts:
  - **Line readout time.** Moth uses the known flicker frequency of mains power (100 or 120 Hz) to work out how long the sensor takes to read each row. It captures twice and only accepts the result if the two readings agree within 3%. This unlocks frequency.
  - **Light response.** Moth then takes five short captures of the same scene, from two stops below to two stops above the metered ISO, and fits how the camera's brightness readings map to actual light. This unlocks depth and the IEEE 1789 verdict. If the fit fails, Moth uses the standard sRGB response the camera is set to, says so on the calibration screen and on every result that relies on it, and lets you retry just this step.

  A calibration only applies to the capture format and measurement method it was made under. When Moth's method changes, it asks you once to recalibrate. Until you do, measuring still works at Tier 3.
- **Settings.** You can set the mains region (50 or 60 Hz), switch between light and dark appearance (dark is the default), turn animations on or off, and enable a debug mode. You can also reset the calibration or erase everything. The app opens with onboarding and a terms screen.

## Measurement tiers

What Moth can report depends on what the device can measure reliably. It never shows a number it can't support:

| Tier | Requires | Reports |
|---|---|---|
| 1: Full measurement | Calibrated, including the light response, and a capture that held the standard exposure | Frequency, depth, IEEE 1789 verdict |
| 2: Frequency only | Calibrated, but the capture couldn't hold the standard exposure | Frequency |
| 3: Presence only | Uncalibrated, or calibrated under an older measurement method | Whether flicker is present |

Each saved measurement records how it was captured (exposure, ISO, measured frame rate, picture size, dropped frames, and whether the light-response curve was applied). You can see these under *Capture details* on the result and in a room's history.

## Standardized capture

Every phone measures under the same forced conditions, so a reading means the same thing on any iPhone and from one visit to the next:

- 29 frames per second, pinned
- a 1920×1080 picture (or the closest size at least 720 rows tall)
- a 1/4000 s exposure on every phone and every measurement
- ISO metered from the scene, with one stop of headroom for the lamp's highlights. ISO is a gain, so it doesn't change the measured depth.
- focus locked at a fixed distance, which deliberately blurs the scene
- white balance locked to 5000 K
- stabilization, HDR, tone mapping and low-light boost turned off

Left to itself, the camera picks its exposure time from the frame rate, which differs between phones. A longer exposure averages some of the flicker away, so the same light would measure shallower on some phones than on others. A fixed exposure removes that difference, and Moth corrects for the small, known attenuation that remains.

One limitation follows from the fixed 29 fps. Moth reads depth from how the flicker drifts in phase from frame to frame. A light that flickers in near-exact step with the frame rate, at a whole multiple of 29 Hz, doesn't drift, so Moth can still report its frequency but not its depth. Mains-powered lighting (100, 120, 200 or 240 Hz) is never a multiple of 29.

## Project layout

| Target | Role |
|---|---|
| `MeasurementCore` | Models, IEEE 1789 limits, guidance, row-brightness extraction, periodogram analysis and calibration solver. Uses no UI or AVFoundation. |
| `MothCapture` | AVFoundation capture under the standard conditions, permissions, device identity and the measurement runner |
| `MothPersistence` | SwiftData store with versioned schema migrations, plus user settings |
| `MothUI` | SwiftUI screens: Measure, Rooms, Buildings, Settings, Calibration and Onboarding |
| `Moth/` | App entry point (`MothApp`) |

## Building

Requires Xcode with Swift 6 and iOS 18 or later. A physical iPhone is needed to measure, because the simulator has no camera.

Open `Moth.xcodeproj` and run the `Moth` scheme on a device.

## Disclaimer

Moth is a benchmarking tool, not a certified or professional flicker meter. Its results are estimates for reference only. They are not medical, safety or compliance advice.
