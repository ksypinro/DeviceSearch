# Device Search demo app

An iOS app for trying the `DeviceSearch` package by hand. It stands in for "your app" in the
[build plan](../docs/design/build-plan.html)'s integration guide: it uses the files in `../AppTarget/DeviceSearch/` as they are (except `AppSetup.swift`,
the template launch file, which `DemoApp.swift` replaces) with a fake device store filled from the
sample homes the tests use.

## Run

Open `DeviceSearchDemo.xcodeproj` in Xcode, pick an iPhone simulator running iOS 26 or later, and run.
For the model re-rank, Apple Intelligence must be on for the Mac (the Simulator uses the Mac's model).

## Tabs

- **Search**: the package's search screen. Sample searches sit under the search bar. The bar at the bottom
  shows the phase (instant, hybrid, refined, fallback), timings, and what the model gate decided.
  Type to see instant results; press Search (return) to submit, since only submitted searches can use the model.
- **Ask** (iOS 27, Apple Intelligence): questions about the home, answered by the on-device model searching
  Spotlight (see "iOS 27 features" below). On iOS 26 and Intel simulators it says it isn't available.
- **Devices**: the fake device store, a 500-device home (the 48 hand-written sample devices plus 452 generated
  ones); Settings switches to the 48-device sample home. Rename, move, switch on or off, set offline, add or delete devices.
  Every change reaches the search index (status at once, renames after the coalesced rebuild).
- **Settings**: feature flags (kill switches), Apple Intelligence status, learned names, and a reset
  that deletes the search data the way sign-out does.

## Things to try

| Search | What should happen |
|---|---|
| `bedrom ac` | "Showing results for bedroom ac" banner |
| `lights except kitchen` | lights everywhere except the kitchen |
| `offline cameras` | only cameras set offline (set one offline in Devices first) |
| `turn off all lights` | a command bar; confirming switches them off in Devices |
| `something to cool the bedroom` | "Meaning: cooling" results: air conditioners and fans |
| `movie night` | TVs and projectors |
| `big screen` | pick the same TV three times from this search; it becomes a learned name (Settings) |

Then rename a device in Devices and search for the new name: it shows up within a second.

## Siri, Shortcuts and Spotlight actions

The app registers six App Shortcuts: turn a device on or off, turn a room's lights on or off, open a device, and
search. Locks, cameras, doorbells and garage doors are never switched. In the iOS 27 beta Simulator, actions
that take a device or room only run when the app carries a team ID. Simulator builds are signed ad hoc, so
re-sign the built app with your own development certificate before installing it:
`codesign --force --deep --sign "Apple Development" DeviceSearchDemo.app`. Without that, the Shortcuts app
reports "an internal error occurred", and the per-device shortcut tiles never appear.

## iOS 27 features

The deployment target stays iOS 26; these turn on when the app runs on iOS 27.

- **Ask tab** (`DeviceAsk.swift`): the on-device model gets Spotlight's `SpotlightSearchTool` over the items the
  indexer donates, plus a `deviceStatus` stage that filters results by live on, off, online or offline state,
  which Spotlight doesn't store. It only looks things up. Tap a device in the answer to open it. Try:
  - "Which lights are on?" (should use the status stage: switch a light in Devices and ask again)
  - "Is anything offline?" (set a device offline first)
  - "What's in the kitchen?"
  - "Which devices did I use today?" (reads the last-used date)
  - The beta Simulator's model fails every request (a content-analysis error), so test on a device.
- **Turn On Devices / Turn Off Devices** (Shortcuts and Siri): several devices in one action, via
  `EntityCollection`. Locks, cameras, doorbells and garage doors are skipped and named in the reply. They have no
  App Shortcut phrase, so find them in the Shortcuts app under this app's actions.
- **Execution targets**: every power intent declares `.main`, so it runs in the app process, where
  `DeviceControl` is registered.
- **Index requests per protection class**: on iOS 27 Spotlight can ask for items by protection class; the
  delegate then returns only items from that index (sensitive devices live in the `.complete` one).

Rows in Devices and in Ask answers also carry their device's entity identifier (iOS 18.4 and later), so Siri
and Apple Intelligence know which device is on screen.

## Spotlight self-test

Launch with `-spotlightSelfTest` to run the Spotlight indexer's scenarios against the real Core Spotlight store:
- first sync
- deletes and renames
- moving a device to and from the secure index
- the Spotlight flag off and on
- lost items found by the launch check
- a relaunch with lost items and a pending change
- reindex-all and reindex-some requests
- items built on demand

Each prints PASS or FAIL to Documents/spotlight-selftest.log. The run replaces the app's Spotlight entries with a
test home; the next normal launch switches back. Run it after any change to `SpotlightIndexer` or
`SpotlightItemMapping`.

## Spotlight comparison

Launch with `-compareSpotlight` (Edit Scheme → Run → Arguments) to run the golden set (380 queries, the
500-device home) through the in-app search, `CSUserQuery`, and, on iOS 27 with Apple Intelligence,
`SpotlightSearchTool`. The app writes `spotlight-comparison.md` (tables) and `spotlight-comparison.json`
(each query's top results) to its Documents folder. `-toolSample N` sets how many queries per category go
to the tool (default 12), `-permissiveGuardrails` relaxes the model's guardrails, and `-probeOnly` runs only
the `CSUserQuery` settings probe. Run it on a device: in the iOS 27 beta Simulator the on-device model
cannot generate and Apple's contextual embeddings cannot load, so the in-app side falls back to the
lexicon embedding and the tool fails.

## Notes

- The demo links the `SearchEvaluation` product only to reach the sample homes (`SyntheticHome`).
  A real app links `DeviceSearch`, `DeviceSearchUI`, `SearchSemantic`, `SearchRerank` and
  `SearchPersonalization`.
- On an 8 GB Mac the on-device model often takes longer than the 2 s limit, so many submitted searches
  end in "Fallback". That is the deadline working, not a crash.
