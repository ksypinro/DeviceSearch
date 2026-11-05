# Apple Spotlight & Core Spotlight — Developer Guide and Smart Home Use Cases

Nov 3, 2026 · @Ksypinro

## Summary

One well-built Spotlight index gives a smart-home app four things: system-wide search of devices, rooms and scenes; one-tap actions; fast offline in-app search; and, from iOS 27, retrieval for on-device LLM answers and Siri.

- **Index the catalogue, not the state.** Homes, rooms, devices and scenes, written from server-confirmed sync events; on, off and sensor values stay out.
- **Put what people type into `displayName` and `title`.** On iOS 17 and later, system Spotlight reportedly matches little else and waits for four typed characters.
- **Associate App Entities with the items.** Siri, Shortcuts and Spotlight on Mac can then find and act on devices, and App Shortcuts surface "Turn on {device}" as a top hit.
- **Drive in-app search with `CSUserQuery`.** Filters, suggestions and ranking come free; treat semantic matching as a bonus, since developers report it often falls back to lexical.
- **Use `SpotlightSearchTool` on iOS 27.** It turns the same index into the retrieval half of a RAG-style search with on-device re-ranking.
- **Expect no home schema domain.** iOS 27's App schema domains cover mail, messages, photos and similar apps, so device control through Siri still runs on App Shortcuts phrases.
- **Keep security state out of results.** Lock, alarm and presence details never appear in titles; sensitive items go in a `.complete` index.

## Overview

Spotlight is Apple's system-wide search, and an app feeds it through a small family of APIs that all write to an on-device index scoped to that app.

| API | What reaches Spotlight | Since | Use it for |
| --- | --- | --- | --- |
| Core Spotlight (`CSSearchableItem`, `CSSearchableIndex`) | Any content you index ahead of time, with rich metadata | iOS 9 | The catalogue: devices, rooms, scenes, events |
| `NSUserActivity` with `isEligibleForSearch` | Screens the user actually visited, donated as they browse | iOS 9 | Recents, history, Siri predictions |
| App Intents `IndexedEntity` | Your `AppEntity` types, written into the same Core Spotlight index | iOS 18 | Content that Siri, Shortcuts and Apple Intelligence should also understand |
| App Intents App Shortcuts | Actions, optionally with a parameter, shown as Spotlight top hits | iOS 16 | One-tap commands such as "turn on" |

A fifth path, web markup crawled by Applebot, covers public web pages; it does not apply to private home data.

**How a result flows.** The system ranks and displays your items. A tap launches your app with an `NSUserActivity` of type `CSSearchableItemActionType` carrying the item's identifier, and your app routes to the right screen.

**One index, several readers.** The index you build for system search also powers search inside your own app: `CSSearchQuery` (iOS 10), `CSUserQuery` with suggestions (iOS 16) and meaning-based semantic search (iOS 18). Other apps cannot query your items.

## Evolution timeline

In eleven years Spotlight went from a launcher for deep links (2015) to the retrieval layer behind in-app semantic search (2024), Mac actions (2025) and Siri plus on-device LLMs (2026).

| Year · OS | WWDC session | What changed |
| --- | --- | --- |
| 2026 · iOS 27 | [246 LLM search using Core Spotlight](https://developer-mdn.apple.com/videos/play/wwdc2026/246/), [240 Build intelligent Siri experiences with App Schemas](https://developer.apple.com/videos/play/wwdc2026/240/), [345 Discover new capabilities in App Intents](https://developer.apple.com/videos/play/wwdc2026/345/) | `SpotlightSearchTool` for Foundation Models; `CSSearchableIndexDescription` and `IndexedEntityQuery` reindexing; entity schemas join the Spotlight semantic index used by Siri; view annotations; `RelevantEntities` |
| 2025 · iOS 26, macOS 26 | [260 Develop for Shortcuts and Spotlight with App Intents](https://developer-mdn.apple.com/videos/play/wwdc2025/260) | Spotlight on Mac runs App Intents; `indexingKey` and `customIndexingKey` on entity properties; auto-generated Find actions |
| 2025 · iOS 18.4 | none | `hideInSpotlight`; `updateListenerOptions` for Apple Intelligence summaries and priority |
| 2024 · iOS 18 | [10131 Support semantic search with Core Spotlight](https://developer.apple.com/videos/play/wwdc2024/10131/) | Semantic and ranked results in `CSUserQuery`; `isUpdate`; `endIndexBatch(expectedClientState:newClientState:)`; index delegate extension template; engagement signals; `IndexedEntity`, `indexAppEntities`, `associateAppEntity` |
| 2023 · iOS 17 | [10102 Spotlight your app with App Shortcuts](https://developer.apple.com/wwdc23/10102), [10193 Design Shortcuts for Spotlight](https://nonstrict.eu/wwdcindex/wwdc2023/10193/) | App Shortcuts as colourful Spotlight top hits, phrase synonyms, parameterised shortcuts |
| 2022 · iOS 16 | [Design App Shortcuts](https://developer.apple.com/videos/play/wwdc2022-10169) | App Intents and App Shortcuts appear in Spotlight; `CSUserQuery` and suggestions added to Core Spotlight |
| 2021 · iOS 15 | [10098 Showcase app data in Spotlight](https://developer.apple.com/wwdc21/10098) | Reworked `NSCoreDataCoreSpotlightDelegate` with start and stop indexing and full-text search |
| 2017 · iOS 11, macOS 10.13 | [231 What's New in Core Spotlight for iOS and macOS](https://nonstrict.eu/wwdcindex/wwdc2017/231/) | Core Spotlight on macOS, Quick Look previews, drag and drop, ranking update |
| 2016 · iOS 10 | [223 Making the Most of Search APIs](https://nonstrict.eu/wwdcindex/wwdc2016/223/) | Search continuation into the app; `CSSearchQuery` for in-app search; privacy-preserving ranking |
| 2015 · iOS 9 | [709 Introducing Search APIs](https://nonstrict.eu/wwdcindex/wwdc2015/709/) | Core Spotlight, searchable `NSUserActivity` and web markup introduced |

## Core concepts

Core Spotlight has three moving parts: an item that identifies one piece of content, the metadata describing it, and an index that stores both on device. [CSSearchableIndex](https://developer.apple.com/documentation/corespotlight/cssearchableindex.md) and [CSSearchableItem](https://developer.apple.com/documentation/corespotlight/cssearchableitem.md) are available on iOS and iPadOS 9+, Mac Catalyst, macOS and visionOS 1+; tvOS is not supported.

| Type | Role | Members you will use most |
| --- | --- | --- |
| `CSSearchableItem` | One searchable thing: a device, a room, a scene | `uniqueIdentifier`, `domainIdentifier`, `attributeSet`, `expirationDate`, `isUpdate`, `associateAppEntity(_:priority:)`, `compare(byRank:)` |
| `CSSearchableItemAttributeSet` | The metadata Spotlight matches on and displays | `contentType`, `title`, `displayName`, `contentDescription`, `textContent`, `keywords`, `thumbnailData`, `contentURL`, `lastUsedDate`, `rankingHint`, `relatedUniqueIdentifier`, custom keys |
| `CSSearchableIndex` | The on-device store; an app may own several named indexes | `init(name:protectionClass:)`, `indexSearchableItems`, three delete methods, batches with client state, `indexDelegate`, `indexAppEntities` |
| `CSSearchableIndexDelegate` | Callbacks from the system to your app or extension | Reindex all, reindex by identifier, throttle notifications, `searchableItems(forIdentifiers:)` |

**Rules that shape every design**

- **Unique identifier.** It is your key back into your own data store, so keep it stable and persisted. Indexing again with the same identifier replaces the item.
- **Domain identifier.** An optional owner or group label. `deleteSearchableItems(withDomainIdentifiers:)` removes a whole group in one call.
- **Minimum metadata.** Apple recommends at least `title`, `displayName` and `contentType`, plus `contentURL` for files.
- **Content type.** Always set a valid `UTType`; semantic search works best on text and media types ([WWDC24 10131](https://developer.apple.com/videos/play/wwdc2024/10131/)).
- **Expiration.** Items expire automatically after an undocumented period unless you set `expirationDate`; community reports put the default near one month ([forum](https://developer.apple.com/forums/thread/116086)). Re-indexing an item extends it.
- **Named indexes in production.** `CSSearchableIndex.default()` is for prototyping only: it has no data protection and no batch support.
- **One writer at a time.** Modify an index from one thread or task at a time, and only from your signed app or extension.
- **Private by design.** Indexes stay on the device, are never shared with Apple, and never sync to the person's other devices ([Core Spotlight](https://developer.apple.com/documentation/corespotlight.md)).

## Indexing content

Index from your data layer whenever content changes, write in batches to a named index, and give the system a way to call you back when it needs a rebuild ([Adding your app's content to Spotlight indexes](https://developer.apple.com/documentation/corespotlight/adding-your-app-s-content-to-spotlight-indexes.md)).

### Attributes worth setting

The attribute set has well over 100 properties ([CSSearchableItemAttributeSet](https://developer.apple.com/tutorials/data/documentation/corespotlight/cssearchableitemattributeset.md)); most apps need about a dozen.

| Attribute | What it does | Smart-home example |
| --- | --- | --- |
| `displayName` | Result name; the field system Spotlight matches most reliably (see Known issues) | "Living Room Lamp" |
| `title` | Core text; processed by the semantic index | "Living Room Lamp" |
| `contentDescription` | Subtitle line under the result | "Dimmable bulb · Living Room" |
| `textContent` | Long text for semantic matching | Model, manufacturer, capabilities in a sentence |
| `keywords`, `alternateNames` | Synonyms and nicknames | "light", "bulb", "couch lamp" |
| `thumbnailData`, `thumbnailURL`, `darkThumbnailURL` | Result icon, with a Dark Mode variant | Device-type glyph |
| `contentType`, `contentTypeTree` | Type used for filtering; custom types inherit from known ones | A custom `UTType` per device class |
| `containerTitle`, `containerIdentifier` | The group the item belongs to | The room or the home |
| `rankingHint` | Relative importance among your own items | Favourites ranked higher |
| `lastUsedDate` | Freshness signal for ranking | Last time the device was controlled |
| `relatedUniqueIdentifier` | Links an item or activity to another item | Ties an `NSUserActivity` to the device item |
| `startDate`, `endDate` | Event timing | An alert or automation run |
| `supportsPhoneCall`, `supportsNavigation` | Adds Call or Directions buttons when the right data is present | Rarely fits; enable only when it is the primary action |
| Custom keys (`CSCustomAttributeKey`) | App-specific fields you can filter on | `roomID`, `deviceClass` |

### Create items and a protected, named index

```swift
import CoreSpotlight
import UniformTypeIdentifiers

let deviceIndex = CSSearchableIndex(name: "Devices",
                                    protectionClass: .completeUntilFirstUserAuthentication)
let sensitiveIndex = CSSearchableIndex(name: "Security", protectionClass: .complete)

func searchableItem(for device: Device) -> CSSearchableItem {
    let attributes = CSSearchableItemAttributeSet(contentType: .content)
    attributes.title = device.name
    attributes.displayName = "\(device.roomName) \(device.name)"
    attributes.contentDescription = "\(device.typeName) · \(device.roomName)"
    attributes.textContent = device.searchSentence
    attributes.keywords = device.synonyms
    attributes.thumbnailData = device.iconPNG

    let item = CSSearchableItem(uniqueIdentifier: "device.\(device.id)",
                                domainIdentifier: "home.\(device.homeID)",
                                attributeSet: attributes)
    item.expirationDate = .now.addingTimeInterval(60 * 60 * 24 * 365)
    return item
}
```

### Batch with client state (iOS 18+ variant shown)

Client state is an opaque blob of at most 250 bytes stored with each batch. Store a sync token in it, read it back with `fetchLastClientState`, and you know exactly where to resume after a crash. `endIndexBatch(expectedClientState:newClientState:)` also rejects the batch if another writer moved the state first ([WWDC24 10131](https://developer.apple.com/videos/play/wwdc2024/10131/)).

```swift
func applySync(changed: [CSSearchableItem], removedIDs: [String], newToken: Data) async throws {
    let lastToken = try? await deviceIndex.fetchLastClientState()
    deviceIndex.beginBatch()
    deviceIndex.indexSearchableItems(changed, completionHandler: nil)
    deviceIndex.deleteSearchableItems(withIdentifiers: removedIDs, completionHandler: nil)
    try await deviceIndex.endIndexBatch(expectedClientState: lastToken, newClientState: newToken)
}
```

The default index does not support batches, and a new batch may start only after the previous one ends.

### Partial updates (iOS 18+)

Set `isUpdate = true` and fill only the attributes that changed; Spotlight merges them instead of replacing the item. Apple pairs this with client state to avoid over-donation, which costs performance.

```swift
let patch = CSSearchableItem(uniqueIdentifier: "device.\(id)", domainIdentifier: nil,
                             attributeSet: CSSearchableItemAttributeSet(contentType: .content))
patch.attributeSet.lastUsedDate = .now
patch.isUpdate = true
try await deviceIndex.indexSearchableItems([patch])
```

### Delete

| Situation | Call |
| --- | --- |
| A device is removed | `deleteSearchableItems(withIdentifiers:)` |
| The person leaves a home | `deleteSearchableItems(withDomainIdentifiers:)` with that home's domain |
| Sign-out or account switch | `deleteAllSearchableItems()` on every named index |
| Indexed `AppEntity` values | `deleteAppEntities(identifiedBy:ofType:)` or `deleteAppEntities(ofType:)` |

### Let the system ask for a rebuild

When Spotlight migrates or recovers an index, it asks your app to reindex everything or a list of identifiers. Answer in two places ([WWDC24 10131](https://developer.apple.com/videos/play/wwdc2024/10131/), [CSSearchableIndexDelegate](https://developer.apple.com/documentation/corespotlight/cssearchableindexdelegate.md)):

- **In-app delegate.** Set `indexDel``8``egate` and implement `searchableIndex(_:reindexAllSearchableItemsWithAcknowledgementHandler:)` and `searchableIndex(_:reindexSearchableItemsWithIdentifiers:acknowledgementHandler:)`. Always call the acknowledgement handler.
- **Index extension.** Add the Core Spotlight Delegate extension target (`CSIndexExtensionRequestHandler`). Spotlight runs it while your app is closed, preferably when the device is idle. It must read your data from a shared App Group container.
- **Throttling.** `searchableIndexDidThrottle(_:)` and `searchableIndexDidFinishThrottle(_:)` tell you when to pause non-critical donations.
- **On-demand items.** `searchableItems(forIdentifiers:)` returns full items by identifier; the iOS 27 `SpotlightSearchTool` uses it to hydrate results.
- **Debugging.** Spotlight launches the extension itself, so attach Xcode to the extension process and trigger a request with the `mdutil` command-line tool, as shown in the WWDC24 demo.

## Opening results

Every tap on one of your results reaches the app as an `NSUserActivity` or an App Intent, so route it through the deep-link path your coordinators already use.

| What the person did | What your app receives | Setup needed |
| --- | --- | --- |
| Tapped a Core Spotlight item | Activity type `CSSearchableItemActionType`; `userInfo[CSSearchableItemActivityIdentifier]` holds your unique identifier | None |
| Tapped **Search in App** | Activity type `CSQueryContinuationActionType`; `userInfo[CSSearchQueryString]` holds the typed query | `CoreSpotlightContinuation` set to true in Info.plist ([docs](https://developer.apple.com/documentation/corespotlight/csquerycontinuationactiontype.md)) |
| Picked a custom action after long-pressing a result | `CSSearchableItemActionType` plus `userInfo[CSActionIdentifier]` | Actions (identifier, title, SF Symbol) declared in Info.plist; `actionIdentifiers` set on the item ([walkthrough](https://betterprogramming.pub/implement-core-spotlight-in-a-swiftui-app-859cb703f55d)) |
| Tapped an indexed `AppEntity` | Spotlight runs your `OpenIntent` for that entity type | One `OpenIntent` per indexed entity type |
| Searched with more than ten matching entities | Spotlight can launch your `ShowInAppSearchResultsIntent` with the criteria | Conform an intent and set `searchScopes` ([docs](https://developer.apple.com/documentation/appintents/making-app-entities-available-in-spotlight.md)) |
| Tapped a donated activity | Your own activity type and `userInfo` | `isEligibleForSearch` on the activity |

### SwiftUI

```swift
WindowGroup {
    RootView()
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
            else { return }
            let action = activity.userInfo?[CSActionIdentifier] as? String
            appCoordinator.route(.spotlightItem(id: id, action: action))
        }
        .onContinueUserActivity(CSQueryContinuationActionType) { activity in
            let query = activity.userInfo?[CSSearchQueryString] as? String ?? ""
            appCoordinator.route(.search(prefill: query))
        }
}
```

### UIKit with scenes

Handle `scene(_:continue:)` for warm launches. On a cold launch the activity arrives in `connectionOptions.userActivities` inside `scene(_:willConnectTo:options:)`, so check both paths before the coordinator starts.

### Custom previews on long press

Add a Quick Look Preview Extension, set `QLSupportsSearchableItems` to YES in its Info.plist, and implement `preparePreviewOfSearchableItem(identifier:queryString:completionHandler:)`. The extension receives your identifier and the query, so it can render fresh content rather than the static indexed snapshot. Share code and data with the app through a package and an App Group.

## In-app search

The index you build for system search can also drive your own search screen: `CSSearchQuery` for structured filters and `CSUserQuery` for what a person types, with semantic matching on iOS 18 and macOS 15 or later ([Building a search interface](https://developer.apple.com/documentation/corespotlight/building-a-search-interface-for-your-app.md)).

|  | `CSSearchQuery` | `CSUserQuery` |
| --- | --- | --- |
| Since | iOS 10 | iOS 16; semantic matching from iOS 18 |
| Input | A predicate string you build | Raw text from the search field |
| Matching | Lexical, attribute by attribute | Lexical plus semantic, ranked results, text suggestions |
| Results | `results` async sequence, or handlers plus `start()` | `responses` async sequence of items and suggestions, or handlers plus `start()` |
| Configuration | `CSSearchQueryContext`: `fetchAttributes`, `filterQueries`; `protectionClasses` on the query | `CSUserQueryContext` adds `maxResultCount`, `maxSuggestionCount`, `enableRankedResults` (default true), `maxRankedResultCount`, `disableSemanticSearch` |
| Smart-home fit | "All offline devices in the kitchen" | "warm light bedroom" typed in the search bar |

### Query language

The same syntax powers `CSSearchQuery` strings and `filterQueries` ([Searching for information in your app](https://developer.apple.com/documentation/corespotlight/searching-for-information-in-your-app.md)).

- **Forms:** `attributeName operator value[modifiers]` or `InRange(attributeName, min, max)`.
- **Operators:** `==`, `!=`, plus `<`, `>`, `<=`, `>=` for numbers and dates. Combine with `&&`, `||` and parentheses.
- **Modifiers:** `c` case-insensitive, `d` ignore diacritics, `w` word boundaries, `t` tokenized, `*` wildcard, `\` escape.
- **Presence:** `attr == "*"` matches items that have the attribute; `attr != "*"` matches items without it.
- **Dates:** the `$time` variable, for example `$time.today(-7)`, `$time.this_week` or `$time.iso(...)`.

```
displayName == "kitchen*"cd
(keywords == "light"wc || keywords == "lamp"wc) && InRange(lastUsedDate, $time.today(-7), $time.now)
contentTypeTree == "com.example.device.light"
```

### CSUserQuery recipe

1. Call `CSUserQuery.prepare()`, or `prepare(protectionClasses:)` for protected indexes, as the search screen appears. Once per run is enough; it costs time and memory, so call it late.
2. Debounce keystrokes by about 0.3 seconds and cancel the previous query. Queries are one-shot objects.
3. Fetch only the attributes the row needs, and scope with `filterQueries` (for example one room or one device class).
4. Read `responses`. Ranked items arrive in batches, so sort once the sequence ends; `CSUserQuery.Item` is `Comparable` and `compare(byRank:)` exists on items.
5. Show suggestions from `localizedAttributedSuggestion`. When one is tapped, put its text in the field and run a new query.
6. Feed ranking: call `userEngaged(_:visibleItems:interaction:)` when a result is opened, and write `lastUsedDate` back with `isUpdate` when the person uses the item ([WWDC24 10131](https://developer.apple.com/videos/play/wwdc2024/10131/)).

```swift
@MainActor @Observable
final class DeviceSearchModel {
    private(set) var results: [CSUserQuery.Item] = []
    private(set) var suggestions: [CSUserQuery.Suggestion] = []
    private var running: Task<Void, Never>?

    func screenWillAppear() { CSUserQuery.prepare() }

    func search(_ text: String, roomID: String?) {
        running?.cancel()
        running = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            let context = CSUserQueryContext()
            context.fetchAttributes = ["displayName", "contentDescription", "thumbnailData"]
            context.maxRankedResultCount = 3
            context.maxSuggestionCount = 5
            if let roomID { context.filterQueries = ["containerIdentifier == \"\(roomID)\""] }

            var items: [CSUserQuery.Item] = []
            var hints: [CSUserQuery.Suggestion] = []
            let query = CSUserQuery(userQueryString: text, userQueryContext: context)
            do {
                for try await response in query.responses {
                    switch response {
                    case .item(let item): items.append(item)
                    case .suggestion(let suggestion): hints.append(suggestion)
                    @unknown default: break
                    }
                }
            } catch { return }
            guard !Task.isCancelled else { return }
            results = items.sorted()   // Item is Comparable by rank; confirm order on device
            suggestions = hints
        }
    }
}
```

**Semantic search reality check.** Apple enables it by default, but developers have reported for over a year that it silently falls back to lexical matching. Logged symptoms include an embedding timeout (code -8007) and `semanticQuery failed to generate`; one workaround is a throwaway warm-up query after `prepare()` ([forum](https://developer.apple.com/forums/thread/793867)). Design your search so lexical matching, good synonyms and your own re-ranking are enough on their own.

## NSUserActivity and Spotlight

Use `NSUserActivity` for the screen the person is looking at right now; it can make that screen searchable, feed Siri suggestions, and tell Siri which entity is on screen. Use Core Spotlight, not activities, for bulk indexing.

| Property | Effect |
| --- | --- |
| `isEligibleForSearch` | Adds the activity to the on-device index |
| `isEligibleForPrediction` | Lets the system suggest returning to this screen |
| `isEligibleForHandoff` | Continue on another device |
| `isEligibleForPublicIndexing` | Candidate for Apple's server-side index; never set it for private home data |
| `contentAttributeSet` | The same `CSSearchableItemAttributeSet` richness as a Core Spotlight item |
| `persistentIdentifier` | Lets you remove it later with `deleteSavedUserActivities(withPersistentIdentifiers:)` |
| `appEntityIdentifier` | Maps the screen to an `AppEntity` for Siri and Apple Intelligence (iOS 18.2+) |

**Avoid duplicate results.** When the same thing is indexed both ways, set the activity's `contentAttributeSet.relatedUniqueIdentifier` to the Core Spotlight item's `uniqueIdentifier`. Index the item first, because an activity pointing at an unknown identifier may not appear. Deleting the item through Core Spotlight also makes the linked activity ineligible ([App Search guide](https://developer.apple.com/library/prerelease/ios/documentation/General/Conceptual/AppSearch/Activities.html), [forum](https://developer.apple.com/forums/thread/7111?page=2)).

**Which metadata wins.** If the two copies differ, Spotlight results show the Core Spotlight metadata and Siri suggestions use the activity's metadata ([Combining APIs](https://developer.apple.com/library/archive/documentation/General/Conceptual/AppSearch/CombiningAPIs.html)).

**Onscreen entities.** One primary item on screen, such as a device detail page, uses `NSUserActivity.appEntityIdentifier`. Several items on screen, such as a room's device list, use the iOS 27 view annotation `.appEntityIdentifier(_:)` on each row ([WWDC26 240 notes](https://github.com/ivan-magda/wwdc26-notes/blob/main/sessions/240-intelligent-siri-experiences-app/digest.md)). On Mac, Spotlight also uses the active entity to suggest intent parameters ([WWDC25 260](https://developer-mdn.apple.com/videos/play/wwdc2025/260)).

```swift
DeviceDetailView(device: device)
    .userActivity("com.example.home.viewDevice") { activity in
        activity.title = device.displayName
        activity.isEligibleForSearch = true
        activity.isEligibleForPrediction = true
        activity.persistentIdentifier = "device.\(device.id)"

        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.relatedUniqueIdentifier = "device.\(device.id)"   // same ID as the indexed item
        activity.contentAttributeSet = attributes

        activity.appEntityIdentifier = EntityIdentifier(for: DeviceEntity.self, identifier: device.id)
    }
```

## App Intents integration

App Intents is now the main road into Spotlight: indexed entities become searchable content, App Shortcuts become top-hit actions, Spotlight on Mac runs intents directly, and Siri reads the same index.

### IndexedEntity (iOS 18+)

Conforming an `AppEntity` to `IndexedEntity` is the only requirement; every protocol property has a default ([Making app entities available in Spotlight](https://developer.apple.com/documentation/appintents/making-app-entities-available-in-spotlight.md)).

- **Map properties to Spotlight keys.** `@Property`, `@ComputedProperty` and `@DeferredProperty` accept `indexingKey: \.contentDescription` for system keys or `customIndexingKey:` for your own. Deferred properties are resolved during indexing, which can slow it down.
- **Add the rest** in `attributeSet`. A wrapped property beats the same key in `attributeSet`, and the entity's `displayRepresentation` title, subtitle and image beat it too. `hideInSpotlight` (iOS 18.4+) keeps an entity out.
- **Donate** with `indexAppEntities(_:priority:)` on a named index. Re-donating an existing ID updates it; higher priority lifts it in suggestions and results.
- **Keep existing Core Spotlight code** and call `associateAppEntity(_:priority:)` on the attribute set or item.
- **Reindex** (iOS 27+) by adopting `IndexedEntityQuery` (`reindexEntities(for:indexDescription:)`, `reindexAllEntities(indexDescription:)`); `CSSearchableIndexDescription` tells you which index to rebuild.
- **Open from results** with one `OpenIntent` per entity type. `ShowInAppSearchResultsIntent` lets Spotlight hand large result sets to your own search screen.
- **Free extras.** Shortcuts auto-generates a Find action from your indexing keys, and the Use Model action receives your exposed entity properties as JSON ([WWDC25 260](https://developer-mdn.apple.com/videos/play/wwdc2025/260)).

```swift
import AppIntents
import CoreSpotlight

struct DeviceEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Device"
    static let defaultQuery = DeviceQuery()

    let id: String

    @Property(indexingKey: \.displayName)
    var name: String

    @Property(indexingKey: \.contentDescription)
    var summary: String          // "Dimmable bulb · Living Room"

    @Property(customIndexingKey: CSCustomAttributeKey(keyName: "com_example_home_room")!)
    var room: String

    var symbolName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(room)",
                              image: .init(systemName: symbolName))
    }
}

struct OpenDeviceIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Device"
    @Parameter(title: "Device") var target: DeviceEntity
}

// After each sync:
try await CSSearchableIndex(name: "Devices").indexAppEntities(entities, priority: 0)
```

### App Shortcuts in Spotlight (iOS 16+)

App Shortcuts need no setup by the person and appear in Spotlight, Siri and the Shortcuts app as soon as the app is installed ([Shortcuts for developers](https://developer.apple.com/shortcuts/)). WWDC23 added colourful top hits, phrase synonyms and parameterised shortcuts that list entities such as "Turn on {device}" ([Design Shortcuts for Spotlight](https://nonstrict.eu/wwdcindex/wwdc2023/10193/)). Call `updateAppShortcutParameters()` when the entity list changes; one developer reports Spotlight can keep showing a stale parameter title even though the shortcut runs with the new value ([forum](https://origin-devforums.apple.com/forums/profile/Teafat)).

### Spotlight on Mac runs your intents (macOS 26)

Since macOS Tahoe, people run app actions straight from Spotlight. An intent qualifies when its parameter summary includes every required parameter without a default, and it is not hidden with `isDiscoverable = false` or as assistant-only ([WWDC25 260](https://developer-mdn.apple.com/videos/play/wwdc2025/260)).

- **Fast parameter filling:** `suggestedEntities()` for big sets, `allEntities()` for small bounded ones, the onscreen `appEntityIdentifier`, and `PredictableIntent` for usage-based suggestions.
- **Typing search:** `EntityStringQuery` or `IndexedEntity`.
- **Background plus foreground:** run quietly, then return an `OpensIntent` that opens the result in the app.
- **iOS apps count:** intents from iOS apps installable on macOS also work in Mac automations.

### Siri and Apple Intelligence read the same index

Indexing entities makes them discoverable by Apple Intelligence ([IndexedEntity](https://developer.apple.com/documentation/appintents/indexedentity.md)). In the 27 releases, entities that also conform to an entity schema join the Spotlight semantic index, so Siri can answer questions about them with attribution to your app ([iOS 27 guide](https://developer.apple.com/wwdc26/guides/ios/)). Data that cannot be indexed ahead of time, such as server-side or fast-changing data, goes through `EntityStringQuery` instead ([WWDC26 240 notes](https://github.com/ivan-magda/wwdc26-notes/blob/main/sessions/240-intelligent-siri-experiences-app/digest.md)).

Apple's own guidance on choosing a discovery channel ([WWDC26 345](https://developer.apple.com/videos/play/wwdc2026/345/)):

| Channel | Use it to |
| --- | --- |
| Spotlight indexing | Make content searchable, including semantically, and retrievable by Siri |
| Interaction donation (`IntentDonationManager`) | Teach the system usage patterns so it suggests repeat actions |
| `RelevantEntities` (iOS 27) | Suggest content that was never searched or used, tied to a context |

## Other integrations

A few more integration points cover Core Data stores, document files, richer result rows and Apple Intelligence summaries; for a smart-home app only the Core Data delegate is likely to matter.

| Integration | What it does | Key APIs | Notes |
| --- | --- | --- | --- |
| Core Data Spotlight delegate | Indexes managed objects and keeps the index in sync on save and delete | `NSCoreDataCoreSpotlightDelegate(forStoreWith:coordinator:)`, `startSpotlightIndexing()`, `stopSpotlightIndexing()`; override `domainIdentifier()`, `indexName()`, `attributeSet(for:)` | Needs a SQLite store with persistent history tracking; tick "Index in Spotlight" per attribute ([WWDC21 10098](https://developer.apple.com/wwdc21/10098)) |
| SwiftData | No dedicated Spotlight delegate is documented | Index models through `IndexedEntity` or Core Spotlight directly | WWDC26 samples pair SwiftData with `EntityStringQuery` |
| Spotlight File Import extension | Spotlight asks your extension for metadata about your document file types | `CSImportExtension.update(_:forFileAt:)`, `CSSupportedContentTypes` in Info.plist | No effect on macOS, which needs a Spotlight importer plugin; may run on several queues at once ([CSImportExtension](https://developer.apple.com/tutorials/data/documentation/corespotlight/csimportextension.md)) |
| Drag and drop | Lets people drag a result into another app | `providerDataTypeIdentifiers`, `providerFileTypeIdentifiers`; delegate `data(for:itemIdentifier:typeIdentifier:)`, `fileURL(for:itemIdentifier:typeIdentifier:inPlace:)` | Data is produced on demand |
| Share from Spotlight | Shares the item straight from the result | `sharedItemContentType` |  |
| Call and directions buttons | Adds Call or Directions to the result | `supportsPhoneCall` with `phoneNumbers`; `supportsNavigation` with `latitude` and `longitude` | Only for the primary action people expect |
| Apple Intelligence summaries and priority | The system summarizes or prioritizes mail, messages and audio transcripts | `updateListenerOptions` (iOS 18.4+), `textContentSummary`, `isPriority`, `transcribedTextContent`, delegate `searchableItemsDidUpdate(_:)` | Aimed at communication apps ([Core Spotlight](https://developer.apple.com/documentation/corespotlight.md)) |

## What's new at WWDC26 (iOS 27)

The 2026 releases turn your Core Spotlight index into retrieval for language models and for Siri: `SpotlightSearchTool` lets a Foundation Models session search it, and entity schemas put indexed content into the semantic index Siri reasons over ([Core Spotlight updates](https://developer.apple.com/documentation/updates/corespotlight.md), [iOS 27 guide](https://developer.apple.com/wwdc26/guides/ios/)).

| Area | Change | What it means for a smart-home app |
| --- | --- | --- |
| Core Spotlight | `SpotlightSearchTool`, a Foundation Models tool that searches your index; iOS, iPadOS, macOS and visionOS | Natural-language device search grounded in your own index |
| Core Spotlight | `CSSearchableIndexDescription` passed to reindex requests | Know which named index to rebuild |
| Core Spotlight | Sample app "Searching indexed content with natural language" (July 2026) | A reference implementation to copy |
| App Intents | Entity schemas plus `IndexedEntity` feed the Spotlight semantic index, with attribution to your app | Siri can find devices, rooms and scenes by meaning |
| App Intents | App schema domains: audio, calendar, camera, clock, files, mail, maps, messages, notes, phone, photos, reminders, plus assistant and Shortcuts-only domains | No home or accessory domain, so Siri control of devices still goes through App Shortcuts phrases ([App schema domains](https://developer.apple.com/tutorials/data/documentation/appintents/app-schema-domains.md)) |
| App Intents | View annotations with `.appEntityIdentifier(_:)` | "Turn this off" while a room's device list is on screen |
| App Intents | `IndexedEntityQuery` reindexing | System-driven rebuilds for entity-based indexes |
| App Intents | `RelevantEntities` with a context | Suggest content nobody has searched or used yet |
| App Intents | `EntityCollection` parameters pass identifiers only | "Turn off every light" over hundreds of devices without resolving each |
| App Intents | `SyncableEntity` for IDs that match across devices | Cloud device IDs are already stable; declaring them lets Siri continue across iPhone and Mac |
| App Intents | `LongRunningIntent` (beyond 30 s, Live Activity progress), `CancellableIntent` (from iOS 26.4) | Firmware updates and long scene transitions |
| App Intents | `ExecutionTargets` | Force state-changing intents into the main app, the single writer |
| Testing | AppIntentsTesting framework; Apple's ladder is AppIntentsTesting, then Shortcuts, Spotlight, Siri | Unit-test entity indexing and intents without UI automation |
| Platform | SiriKit formally deprecated, with Xcode 27 warnings (third-party reports) | Port any SiriKit intents to App Intents ([Bitrise](https://bitrise.io/blog/post/wwdc26-under-the-radar)) |

Sources for the App Intents rows: [WWDC26 345](https://developer.apple.com/videos/play/wwdc2026/345/), [WWDC26 240 notes](https://github.com/ivan-magda/wwdc26-notes/blob/main/sessions/240-intelligent-siri-experiences-app/digest.md).

### SpotlightSearchTool in practice

The tool adopts the Foundation Models `Tool` protocol. The model writes a Spotlight query, Spotlight runs it, and the model answers from the results ([WWDC26 246](https://developer-mdn.apple.com/videos/play/wwdc2026/246/)).

```swift
import CoreSpotlight
import FoundationModels

// On-device models have a small context, so keep guidance focused.
let tool = SpotlightSearchTool(configuration: .init(guide: .init(level: .focused(.items))))

let session = LanguageModelSession(
    model: SystemLanguageModel.default,
    tools: [tool],
    instructions: "Answer only about devices in this home. Use the search tool.")

let answer = try await session.respond(to: "Which bedroom devices haven't been used this week?")

// Results also stream on the tool itself, for list-style UI.
for await reply in tool.searchResults {
    if case .items(let items) = reply.content { render(items, section: reply.queryToken) }
}
```

- **Hydrate full items.** Text content and HTML are stored in a compact form the model cannot read back. Implement `searchableItems(forIdentifiers:)` on your index delegate to return full items, plus any extra attributes worth reasoning over.
- **Scope guidance.** `GuidanceProfile` turns capabilities on or off (text match, dates, people) and can list the exact attributes the model may use.
- **Custom pipeline stages.** Register `@Generable` stages that score or filter items; the model can chain search and computation, and replies may carry counts, tables or statistics.
- **Resolve people** with a `ContactResolver` when queries mention household members.
- **Measure** result coverage with the Evaluations framework before shipping.

## Privacy, performance, testing and known issues

The index is private and local, but anyone holding the unlocked phone can read it; most production problems come from stale data, over-donation and OS-version quirks in what system Spotlight actually matches.

### Privacy and security

- **Where the data lives.** Indexes stay on the device, are never shared with Apple, never sync to other devices, and no other app can query them ([Core Spotlight](https://developer.apple.com/documentation/corespotlight.md), [WWDC24 10131](https://developer.apple.com/videos/play/wwdc2024/10131/)).
- **Who can see results.** Spotlight shows your items to whoever uses the device. Keep sensitive state out of titles and descriptions, and put sensitive items in a `.complete` index, which is encrypted and unreadable while the device is locked.
- **Querying protected indexes.** Use `CSUserQuery.prepare(protectionClasses:)` and `CSSearchQuery.protectionClasses`.
- **Public indexing.** Never set `isEligibleForPublicIndexing` on private data.
- **Sensitive actions.** App Intents schemas can carry an authentication policy such as `.requiresAuthentication`, which Apple shows for destructive photo actions ([WWDC26 347](https://developer.apple.com/fr/videos/play/wwdc2026/347/)); apply the same thinking to locks and alarms.

### Performance

- Batch large updates, keep client state under 250 bytes, and combine it with `isUpdate` so you donate only what changed.
- Let the index delegate extension handle rebuilds so the system can schedule them for idle time; pause non-critical donations when throttled.
- Call `CSUserQuery.prepare()` late and once per run; it costs time and memory.
- Fetch only the attributes a result row needs, and debounce typing by about 0.3 s.
- Write to each index from one thread or task at a time; avoid expensive `@DeferredProperty` values on indexed entities.

### Testing and debugging

1. **Reindex requests:** attach Xcode to the extension and trigger a request with `mdutil` ([WWDC24 10131](https://developer.apple.com/videos/play/wwdc2024/10131/)).
2. **Semantic search:** watch Console for `CSUserQuery` lines such as `semanticQuery failed to generate` ([forum](https://developer.apple.com/forums/thread/793867)).
3. **Entities:** AppIntentsTesting can query Spotlight for entities in tests; one developer uses `AppEntityDefinition.spotlightQuery(_:)` ([forum](https://developer.apple.com/forums/thread/837319)).
4. **The full ladder:** AppIntentsTesting, then the Shortcuts app, then Spotlight, then Siri ([WWDC26 240 notes](https://github.com/ivan-magda/wwdc26-notes/blob/main/sessions/240-intelligent-siri-experiences-app/digest.md)).
5. **Device quirks:** the Search in App button can need a device restart to appear, and custom actions only show after deleting and re-indexing existing items ([walkthrough](https://betterprogramming.pub/implement-core-spotlight-in-a-swiftui-app-859cb703f55d)).

### Known issues reported by developers

| Issue | Seen on | Workaround |
| --- | --- | --- |
| System Spotlight matches mainly `displayName` and `title`; `keywords`, `alternateNames` and `textContent` are ignored, while `CSUserQuery` still finds them | iOS 17 and later; again in OS 27 beta 3 ([thread](https://developer.apple.com/forums/thread/734996), [thread](https://developer.apple.com/forums/thread/781872), [thread](https://developer.apple.com/forums/thread/837319)) | Put the words people type (room, device type) into `displayName` and `title` |
| Third-party results appear only after more than three typed characters | iOS 17 and later ([thread](https://developer.apple.com/forums/thread/818717)) | Make names distinctive within the first word |
| Semantic search silently behaves as lexical; embedding timeout -8007 | iOS 18 to 26 ([thread](https://developer.apple.com/forums/thread/793867)) | Warm-up query after `prepare()`; never depend on semantics alone |
| Items disappear after about a month | Long-standing ([thread](https://developer.apple.com/forums/thread/116086)) | Set `expirationDate`; re-index on full sync |
| An `IndexedEntity` indexes only its display name, not `textContent` | iOS 18 ([forum tag](https://developer.apple.com/forums/tags/core-spotlight)) | Map fields with `indexingKey`, or index a full item and `associateAppEntity` |
| A linked `NSUserActivity` never appears | When the related item is not indexed yet ([thread](https://developer.apple.com/forums/thread/7111?page=2)) | Index the Core Spotlight item first |
| App Shortcut parameter title stays stale in Spotlight after `updateAppShortcutParameters()` | iOS 26 ([forum](https://origin-devforums.apple.com/forums/profile/Teafat)) | Keep titles stable; file feedback |

## Smart home: what to index and the use cases

Index the slow-changing catalogue of homes, rooms, devices and scenes; keep live device state out of the system index; and route anything that changes a device through App Intents.

### What to index

| Entity | Index as | Identifier · domain | Key attributes | Refresh |
| --- | --- | --- | --- | --- |
| Device | Core Spotlight item with an associated `DeviceEntity` | `device.<id>` · `home.<homeID>` | `displayName` "Living Room AC"; `contentDescription` type · brand · room; `textContent` one sentence with model and capabilities; `keywords` synonyms; `containerTitle` room; custom keys for class, room, brand | On confirmed change; usage via `isUpdate` |
| Room | Item plus `RoomEntity` | `room.<id>` · `home.<homeID>` | `displayName` "Kitchen"; `contentDescription` "9 devices" | On change |
| Scene or routine | Item plus `SceneEntity`, and an App Shortcut "Run {scene}" | `scene.<id>` · `home.<homeID>` | `displayName` "Good Night"; what it does in one line | On change |
| Automation | Item | `automation.<id>` · `home.<homeID>` | Trigger and effect summary | On change |
| Home or location | Item plus `HomeEntity` | `home.<id>` · `home.<id>` | Name, room and device counts | On change |
| Alerts and events (optional) | Items in a separate `.complete` index, with `expirationDate` | `event.<id>` · `home.<homeID>` | `startDate`; "Motion · Front door camera" | Expire after days |
| Live state (on, off, level, temperature) | Not indexed | none | Shown live in previews, widgets, controls and the app | Seconds |

For a home with up to 500 devices, each carrying a name, manufacturer and type such as AC, TV or light, this is a few hundred small items per home, well suited to batch indexing.

### Use-case catalogue

| # | Use case | Spotlight feature | Minimum OS |
| --- | --- | --- | --- |
| 1 | Find any device by name, room, type or brand from Home Screen search and open its screen | Core Spotlight items, deep link via `CSSearchableItemActionType` | iOS 9 |
| 2 | Jump straight into a room, scene or home | Room, scene and home items; `OpenIntent` for entities | iOS 16 |
| 3 | Run "Turn on {device}" or "Run {scene}" from a Spotlight top hit without opening the app | Parameterised App Shortcuts with background intents | iOS 17 |
| 4 | Long-press a device result and pick Turn Off | Custom actions via `actionIdentifiers`; the app opens with `CSActionIdentifier` | iOS (verify on current OS) |
| 5 | Peek at live temperature, power or a camera snapshot before opening | Quick Look preview extension for searchable items | iOS 11 |
| 6 | Search 500 devices inside the app, offline, with room and type chips and suggestions | `CSUserQuery` with `filterQueries`, ranked results, engagement | iOS 16; semantic iOS 18 |
| 7 | Ask "which bedroom devices are offline?" in natural language | `SpotlightSearchTool` with a custom pipeline stage that checks live state | iOS 27 |
| 8 | Ask Siri to find a device or scene by meaning | `IndexedEntity` in the semantic index; App Shortcuts phrases for actions | iOS 18; richer in 27 |
| 9 | Say "turn this off" while a device or room list is on screen | `NSUserActivity.appEntityIdentifier`, view annotations | iOS 18.2; lists iOS 27 |
| 10 | Continue a broad Spotlight search like "lights" inside the app | Search in App via `CoreSpotlightContinuation` | iOS 10 |
| 11 | See "Turn off porch light" suggested at the usual time | `isEligibleForPrediction`, interaction donation, `PredictableIntent` | iOS 12+ |
| 12 | Control devices from Spotlight on a Mac or iPad app | App Intents with a full parameter summary, `suggestedEntities()` | macOS 26 |
| 13 | "Turn off every light" across hundreds of devices quickly | `EntityCollection` parameters | iOS 27 |
| 14 | Search past events: "front door this week" | Event items with `startDate` and `$time` filters in `CSSearchQuery` | iOS 10 |
| 15 | Build Shortcuts that find devices by property, or reason over them with Use Model | Auto-generated Find action from indexing keys | iOS 26 |
| 16 | Leave a shared home and have every result disappear | `deleteSearchableItems(withDomainIdentifiers:)` | iOS 9 |

Market proof: the HomeSpot app searches HomeKit devices from Spotlight with live states and, on macOS, toggles them straight from the results ([App Store](https://apps.apple.com/us/app/homespot/id6757016819)). Home Assistant's companion app exposes light, switch, fan and cover control as App Intents that run from Spotlight ([docs](https://companion.home-assistant.io/docs/integrations/siri-shortcuts/)).

## Smart home: reference architecture for an MVVM-C app

Treat the Spotlight index as one more read model: a projector fed by server-confirmed changes writes it through a protocol, the coordinator tree consumes taps, and search features read it back.

&#91;embedded content: Spotlight indexing architecture · write path, indexes, readers\]

The projector writes only server-confirmed changes; every reader, from system Spotlight to the iOS 27 LLM tool, queries the same on-device indexes, and every tap comes back through the coordinator tree.

### Building blocks

| Component | Responsibility | Lives in |
| --- | --- | --- |
| `SpotlightIndexing` (protocol) and `CoreSpotlightIndexer` (actor) | Single writer for the named indexes; batches with client state | Shared framework used by app and extensions |
| `SpotlightItemMapping` | Turns `Device`, `Room`, `HomeScene` into items and associates entities | Shared framework |
| Index projector | Subscribes to confirmed store events (not optimistic ones) and calls the indexer | App data layer |
| `SpotlightID` | Stable identifier scheme, parsed back for routing | Shared framework |
| Index delegate and index extension | Rebuild on request from the App Group copy of the store | App and extension target |
| App Intents module | `DeviceEntity`, `RoomEntity`, `SceneEntity`, control intents, App Shortcuts | Shared package; state-changing intents target the main app |
| Deep-link router | Converts activities and `OpenIntent`s into coordinator routes | `AppCoordinator` |
| `DeviceSearching` | In-app search: Spotlight retrieval plus optional on-device re-ranking | Search feature module |
| Quick Look preview extension | Live state on long press | Extension target |

### Identifier scheme

```swift
enum SpotlightID: Hashable {
    case home(String), room(String), device(String), scene(String)

    var rawValue: String {
        switch self {
        case .home(let id): "home.\(id)"
        case .room(let id): "room.\(id)"
        case .device(let id): "device.\(id)"
        case .scene(let id): "scene.\(id)"
        }
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "home": self = .home(parts[1])
        case "room": self = .room(parts[1])
        case "device": self = .device(parts[1])
        case "scene": self = .scene(parts[1])
        default: return nil
        }
    }
}
```

### Indexing service

```swift
protocol SpotlightIndexing: Sendable {
    func apply(_ changes: HomeChangeSet, syncToken: Data) async throws   // token ≤ 250 bytes
    func noteUsed(_ id: SpotlightID) async
    func removeHome(_ homeID: String) async throws
    func removeEverything() async throws
}

actor CoreSpotlightIndexer: SpotlightIndexing {
    private let catalog = CSSearchableIndex(name: "HomeCatalog",
                                            protectionClass: .completeUntilFirstUserAuthentication)
    private let mapper: SpotlightItemMapping

    init(mapper: SpotlightItemMapping) { self.mapper = mapper }

    func apply(_ changes: HomeChangeSet, syncToken: Data) async throws {
        let upserts = changes.devices.map(mapper.item(for:))
                    + changes.rooms.map(mapper.item(for:))
                    + changes.scenes.map(mapper.item(for:))
        let removals = changes.removedIDs.map(\.rawValue)

        let previous = try? await catalog.fetchLastClientState()
        catalog.beginBatch()
        catalog.indexSearchableItems(upserts, completionHandler: nil)
        catalog.deleteSearchableItems(withIdentifiers: removals, completionHandler: nil)
        try await catalog.endIndexBatch(expectedClientState: previous, newClientState: syncToken)
    }

    func noteUsed(_ id: SpotlightID) async {
        let patch = CSSearchableItem(uniqueIdentifier: id.rawValue, domainIdentifier: nil,
                                     attributeSet: CSSearchableItemAttributeSet(contentType: .content))
        patch.attributeSet.lastUsedDate = .now
        patch.isUpdate = true
        try? await catalog.indexSearchableItems([patch])
    }

    func removeHome(_ homeID: String) async throws {
        try await catalog.deleteSearchableItems(withDomainIdentifiers: ["home.\(homeID)"])
    }

    func removeEverything() async throws {
        try await catalog.deleteAllSearchableItems()
    }
}
```

The mapper builds each item as shown in Indexing content, then calls `attributes.associateAppEntity(DeviceEntity(device), priority: device.isFavorite ? 10 : 1)`. Keeping full Core Spotlight items and associating entities gives you exact control over `displayName`, which matters given the matching quirks, while still feeding Siri and Shortcuts.

### Hooking into an offline-first store

- **Project confirmed events only.** Index after the server acknowledges a change, never on the optimistic write, so a rolled-back rename never reaches Spotlight and the saga's compensation step needs no Spotlight logic.
- **Use the sync cursor as client state.** Encode the server cursor plus an index schema version; a version bump forces a full rebuild after an app update.
- **Coalesce usage signals.** Debounce `noteUsed` per device so a dimmer slider does not write to the index on every tick.
- **Share the store with extensions.** Keep a read-only copy in the App Group so the index extension and preview extension work while the app is closed.

### Routing a tap through the coordinator tree

```swift
extension AppCoordinator {
    func handleSpotlight(_ activity: NSUserActivity) {
        guard let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let id = SpotlightID(rawValue: raw) else { return }
        let quickAction = (activity.userInfo?[CSActionIdentifier] as? String)
            .flatMap(DeviceQuickAction.init(rawValue:))

        switch id {
        case .home(let homeID): switchHome(to: homeID)
        case .room(let roomID): homeCoordinator.showRoom(roomID)
        case .device(let deviceID): homeCoordinator.showDevice(deviceID, then: quickAction)
        case .scene(let sceneID): homeCoordinator.showScene(sceneID)
        }
    }
}
```

### In-app search: Spotlight retrieval plus on-device re-ranking

Spotlight does the fast, offline candidate retrieval; a Foundation Models session re-ranks only when the query reads like a sentence, and every returned ID is validated against the candidate list.

```swift
protocol DeviceSearching {
    func search(_ text: String, scope: SearchScope) async throws -> [DeviceHit]
}

struct RerankedDeviceSearch: DeviceSearching {
    let retriever: DeviceSearching          // CSUserQuery-backed, top 30
    let reranker: DeviceReranking           // Foundation Models

    func search(_ text: String, scope: SearchScope) async throws -> [DeviceHit] {
        let candidates = try await retriever.search(text, scope: scope)
        let isSentence = text.split(separator: " ").count >= 3
        guard isSentence, candidates.count > 1 else { return candidates }
        return try await reranker.rerank(query: text, candidates: Array(candidates.prefix(20)))
    }
}

@Generable
struct RankedDevices {
    @Guide(description: "IDs copied from the candidate list, best match first")
    var ids: [String]
}

struct FoundationModelsReranker: DeviceReranking {
    func rerank(query: String, candidates: [DeviceHit]) async throws -> [DeviceHit] {
        let session = LanguageModelSession(
            instructions: "Rank smart-home devices for the request. Use only IDs from the list.")
        let list = candidates
            .map { "\($0.id): \($0.name), \($0.typeName), \($0.roomName), \($0.manufacturer)" }
            .joined(separator: "\n")
        let response = try await session.respond(
            to: "Request: \(query)\nCandidates:\n\(list)", generating: RankedDevices.self)

        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let ranked = response.content.ids.compactMap { byID[$0] }      // drops invented IDs
        let rest = candidates.filter { !response.content.ids.contains($0.id) }
        return ranked + rest
    }
}
```

On iOS 27 you can replace the hand-built pipeline with `SpotlightSearchTool`: implement `searchableItems(forIdentifiers:)` on the index delegate to attach live state from the cache, and register a custom stage that drops offline or incapable devices.

## Smart home: security, freshness, lifecycle and rollout

Ship the catalogue first, keep security-relevant state out of system search, and tie every index change to the account and home lifecycle.

### Security and privacy rules

- **No live security state in system results.** Titles and descriptions never say "Front door unlocked", "Alarm disarmed" or "Nobody home"; anyone holding the unlocked phone sees them.
- **Separate sensitive items.** Put locks, cameras, alarms and event history in a `.complete` index, or keep entities out of Spotlight results with `hideInSpotlight` (iOS 18.4+).
- **Gate sensitive actions.** Unlock, disarm and open-garage intents require authentication and an explicit confirmation, and never run as silent background App Shortcuts.
- **Index only what this user may access.** In shared households, remove a home's domain the moment the server revokes access.
- **Mind personal names.** "Anna's room" stays on the device, but it shows in Spotlight to anyone using it.

### Freshness strategy

| Data | Changes | Where it belongs |
| --- | --- | --- |
| Name, room, type, brand, capabilities | Rarely | System index, written on confirmed change |
| Favourites, last used | Daily | `rankingHint` and `lastUsedDate` patches with `isUpdate`, debounced |
| Online, offline, battery low | Hourly | Live cache; in-app filters and the `SpotlightSearchTool` hydration step |
| On, off, level, temperature, motion | Seconds | Never indexed; previews, widgets, controls, Live Activities |
| Alerts and events | In bursts | Protected event index with `expirationDate` and a cap |

### Account and home lifecycle

| Event | Index action |
| --- | --- |
| First sign-in | Full index after the first sync, in batches, with the sync cursor as client state |
| Every confirmed sync | Batch of upserts and deletions; client state moves forward |
| Switch active home | No index change; scope in-app queries with `filterQueries` on the home |
| Leave a home or lose access | `deleteSearchableItems(withDomainIdentifiers:)` and `deleteAppEntities(identifiedBy:ofType:)` |
| Sign-out | `deleteAllSearchableItems()` on every named index; delete saved activities; clear `RelevantEntities` |
| App update with a new schema | Version bump in client state triggers a full rebuild |
| System reindex request | Delegate or extension rebuilds from the App Group store |

### Rollout plan

1. **Catalogue in Spotlight (iOS 17 baseline).** Devices, rooms and scenes as items; deep links through the coordinators; deletion lifecycle; index extension. Gate: every item type opens the right screen from cold and warm launch, and an `mdutil` reindex succeeds with the app closed.
2. **App Intents.** Associate `DeviceEntity`, `RoomEntity` and `SceneEntity`; add `OpenIntent`s, toggle and run-scene intents, parameterised App Shortcuts and Spotlight on Mac support. Gate: AppIntentsTesting suite green, and the Shortcuts Find action lists devices.
3. **In-app search.** `CSUserQuery` with room and type filters, suggestions and engagement signals, then optional Foundation Models re-ranking. Gate: a relevance test set of real queries passes the bar your team sets, fully offline.
4. **iOS 27 intelligence.** `SpotlightSearchTool` Q&A with a live-state stage, view annotations, `SyncableEntity`, `EntityCollection` bulk actions, and `RelevantEntities` where a context fits. Gate: result coverage measured with the Evaluations framework.

### Test checklist

- [ ] Each indexed type opens the right screen from cold launch and from background.
- [ ] Renaming a device updates Spotlight after one sync; a rejected optimistic rename never appears.
- [ ] Deleting a device, leaving a home and signing out each remove the right results.
- [ ] Results appear for "room + device" queries typed in system Spotlight (more than three characters).
- [ ] Security items are unreadable while the device is locked.
- [ ] A reindex request rebuilds the index from the App Group store with the app closed.
- [ ] A 500-device home: full rebuild time and peak memory measured, batch size tuned.
- [ ] A sentence-style query ("something to cool the bedroom") is logged: semantic hit or lexical fallback.
- [ ] "Turn on {device}" runs from Spotlight on Mac with suggested devices.
- [ ] Names and synonyms work in every shipped language.

## Sources

Pages read in full while writing this guide, as of November 2026.

**Apple documentation**

- [Core Spotlight](https://developer.apple.com/documentation/corespotlight.md) and [Core Spotlight updates](https://developer.apple.com/documentation/updates/corespotlight.md)
- [Adding your app's content to Spotlight indexes](https://developer.apple.com/documentation/corespotlight/adding-your-app-s-content-to-spotlight-indexes.md)
- [Building a search interface for your app](https://developer.apple.com/documentation/corespotlight/building-a-search-interface-for-your-app.md)
- [Searching for information in your app](https://developer.apple.com/documentation/corespotlight/searching-for-information-in-your-app.md)
- [CSSearchableIndex](https://developer.apple.com/documentation/corespotlight/cssearchableindex.md), [CSSearchableItem](https://developer.apple.com/documentation/corespotlight/cssearchableitem.md), [CSSearchableItemAttributeSet](https://developer.apple.com/tutorials/data/documentation/corespotlight/cssearchableitemattributeset.md), [CSUserQueryContext](https://developer.apple.com/documentation/corespotlight/csuserquerycontext.md)
- [Making app entities available in Spotlight](https://developer.apple.com/documentation/appintents/making-app-entities-available-in-spotlight.md)

**WWDC sessions**

- [WWDC24 10131 Support semantic search with Core Spotlight](https://developer.apple.com/videos/play/wwdc2024/10131/)
- [WWDC25 260 Develop for Shortcuts and Spotlight with App Intents](https://developer-mdn.apple.com/videos/play/wwdc2025/260)
- [WWDC26 246 LLM search using Core Spotlight](https://developer-mdn.apple.com/videos/play/wwdc2026/246/)
- [WWDC26 345 Discover new capabilities in the App Intents framework](https://developer.apple.com/videos/play/wwdc2026/345/)
- [WWDC26 240 Build intelligent Siri experiences with App Schemas (community digest)](https://github.com/ivan-magda/wwdc26-notes/blob/main/sessions/240-intelligent-siri-experiences-app/digest.md)

**Community and forums**

- [Core Spotlight semantic search still non-functional?](https://developer.apple.com/forums/thread/793867)
- [Spotlight only finds title attribute (OS27 b3)](https://developer.apple.com/forums/thread/837319)
- [Implement Core Spotlight in a SwiftUI app](https://betterprogramming.pub/implement-core-spotlight-in-a-swiftui-app-859cb703f55d)

Also cited from search excerpts: [CSSearchableIndexDelegate](https://developer.apple.com/documentation/corespotlight/cssearchableindexdelegate.md), [CSQueryContinuationActionType](https://developer.apple.com/documentation/corespotlight/csquerycontinuationactiontype.md), [IndexedEntity](https://developer.apple.com/documentation/appintents/indexedentity.md), [App schema domains](https://developer.apple.com/tutorials/data/documentation/appintents/app-schema-domains.md), [iOS 27 guide](https://developer.apple.com/wwdc26/guides/ios/), [WWDC21 10098](https://developer.apple.com/wwdc21/10098), [WWDC17 231](https://nonstrict.eu/wwdcindex/wwdc2017/231/), [WWDC16 223](https://nonstrict.eu/wwdcindex/wwdc2016/223/), [WWDC15 709](https://nonstrict.eu/wwdcindex/wwdc2015/709/), forum threads [734996](https://developer.apple.com/forums/thread/734996), [781872](https://developer.apple.com/forums/thread/781872), [818717](https://developer.apple.com/forums/thread/818717), [116086](https://developer.apple.com/forums/thread/116086), [HomeSpot](https://apps.apple.com/us/app/homespot/id6757016819), [Home Assistant App Intents](https://companion.home-assistant.io/docs/integrations/siri-shortcuts/).
