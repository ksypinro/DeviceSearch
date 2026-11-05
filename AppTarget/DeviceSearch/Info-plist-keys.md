# Info.plist keys for device search

| Key | Value (edit the wording) | Needed from |
|---|---|---|
| `NSMicrophoneUsageDescription` | "Say a device name to search for it." | Milestone 4 (voice) |
| `NSSpeechRecognitionUsageDescription` | "Speech is turned into text on this device to search your devices." | Milestone 4 (voice) |
| `CoreSpotlightContinuation` | `YES` | "Search in App" from Spotlight opens the app's search (`SystemActivities.swift`) |
| `NSUserActivityTypes` | `$(PRODUCT_BUNDLE_IDENTIFIER).viewDevice` | The device screen's activity (`deviceActivity(_:)`) |

Foundation Models, Natural Language and App Intents need no keys. App Intents metadata is extracted at build time
from the app target (keep `DeviceEntity` and the intents there). The demo app adds the last two keys through
`DemoApp/DeviceSearchDemo-Info.plist`, which Xcode merges into the generated Info.plist.
