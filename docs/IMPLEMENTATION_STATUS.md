# Roadmap v2 implementation status

> **Snapshot from 24 September 2026.** Later work is recorded in
> [development history](DEVELOPMENT_HISTORY.md) and
> [guidance review update](GUIDANCE_REVIEW_UPDATE.md). The baseline commit named
> below as `c2dbacf` appears on GitHub as `ec804eb` (same file tree).

Updated 24 September 2026. This records implemented code separately from planned acceptance gates.

## Canonical project and baseline

`Racing Trainer-3` is the canonical project and Git repository. The sibling
`Versions` directory contains historical copies. The parent folder contains the
original Word roadmap and the v2 Word and Markdown roadmaps.

The original source was committed as `c2dbacf` and tagged `baseline-v2` before
implementation edits. An unsigned Debug build of that baseline succeeded with
Xcode 26.5 (17F42). There is no configured remote or public release.

## Implemented safety increment

- Added a hostless XCTest target and shared Xcode scheme. The tests compile the
  same policy and model files as the app; they do not launch capture or request
  camera permissions.
- Added timestamped `PerceptionObservation<Value>` with explicit fresh, stale,
  uncertain and missing states, source generation, confidence, implementation,
  version and diagnostic reason.
- Added pure `CoachSafetyPolicy` and evidence-bearing `CoachDecision`. Both full
  route detection and lightweight tracked frames invoke the policy.
- Removed the missing-speed BRAKE branches for sharp turns and U-turns.
- Require finite timestamps, completion after capture, completion before the
  decision, valid confidence, same active source generation, bounded evidence
  age, and synchronized speed/route timestamps.
- Require consistent straight direction/severity/timing and four stable frames
  before acceleration advice. Existing numeric brake thresholds remain unchanged.
- Reject speed outside the existing numeric HUD range of 0–500 km/h.
- Expire published guidance when the earliest required observation expires;
  the existing driving view evaluates expiration on its timeline refresh.
- Do not refresh coaching evidence timestamps when a rejected speed jump merely
  returns an old stabilized display value.

| Route evidence | Speed evidence | Policy result |
| --- | --- | --- |
| Fresh, confident, valid session | Fresh, confident, synchronized, valid session | Apply speed-aware policy |
| Fresh, confident, valid session | Missing, stale, uncertain, invalid or wrong session | HOLD with direction-only explanation |
| Missing, stale, uncertain, invalid or wrong session | Any | Guidance unavailable |

The current policy limits are 650 ms route age, 750 ms speed age, 750 ms
timestamp skew, 0.52 route confidence and 0.30 speed confidence. These are
prototype limits, not calibrated guarantees. OCR reliability remains unproven.

## Verification

Run from this directory:

```sh
bash scripts/check.sh build
bash scripts/check.sh test
```

Build products go to ignored `DerivedData/`. Override that location with
`RACING_TRAINER_DERIVED_DATA`. No Apple developer signing identity is required.
Xcode's macOS test runner needs access to its system test service; a restricted
automation sandbox can compile the suite but block its execution.

The application and test target compiled, and **11 XCTest methods passed with
zero failures** on 24 September 2026. Tests cover the 16 route/speed state
combinations, 360 missing-speed direction/severity/timing combinations,
the original sharp/U-turn regressions, threshold boundaries, stale readings,
source-generation changes, invalid timestamps/confidence/values, acceleration
prerequisites and published decision expiration.

These are policy/model unit tests plus an app build. They do not establish OCR
accuracy, full pipeline reset behavior under concurrency, live capture
correctness, thermal performance or driving calibration.

## Dataset inventory and remaining Phase 0 work

| Asset | Location / evidence | Status |
| --- | --- | --- |
| Existing reports and generated weights | `Training/` and `Racing Trainer/*Weights.swift` | Present in baseline Git commit |
| Reviewed sample counts | `Training/source_holdout_training_report.json` | Reports 582 pairs, 526 positive and 56 empty masks; not re-audited here |
| App dataset container | `/Users/sean/Library/Containers/NoName.Racing-Trainer/Data/Library/Application Support/Racing Trainer/` | Directory exists, but macOS denies content access even outside the automation sandbox |
| Default raw crop location | Container above plus `Dataset/minimap/raw` | Derived from recorder source; contents unverified |
| Known source recording | `/Users/sean/Downloads/BMW M4 Competition Coupe - The Crew Motorfest _ Thrustmaster TX - Gameplay Steeringwhee_1080p60.mp4` | File located; not decoded or evaluated in this increment |
| Reviewed export manifest and other original recordings | Not yet verified | Needed before immutable recording-level splits can be built |

For the next dataset step, use the app's **Export reviewed pairs** flow to put an
export in an accessible project data directory. Keep raw media and generated
datasets outside source control. No retraining or holdout tuning was performed.

## Remaining work

Phase 0 remains open until the reviewed export and original recordings are
verified. This is the first Phase 1 safety increment, not completion of the
roadmap. Next: integration tests for source changes and in-flight results,
shared frame contracts and deterministic replay with a virtual clock,
versioned dataset manifests and reports, then OCR recovery. Model experiments,
voice coaching, event-level calibration and live validation remain later work.
