# DeviceSearchTool: design

A Foundation Models tool that lets a language model search this app's devices with our own search engine, the way `SpotlightSearchTool` lets it search the Core Spotlight index.

Status: proposal, not implemented. Written 2026-11-05 against the iOS 27.0 beta SDK (Xcode-beta).

## Summary

- **Apple's tool model is simple.** A tool is a `Sendable` type with a name, a one-line description, `@Generable` arguments and a `call(arguments:)` that returns text or a `@Generable` value. The `Tool` protocol exists from **iOS 26.0**, so a tool of our own runs on every Apple Intelligence device we support. `SpotlightSearchTool` needs iOS 27.
- **Context is the constraint.** The on-device model has 4,096 tokens per session, and tool definitions, arguments and output all count. Apple's guidance: short descriptions, three to five tools at most, and compact output.
- **SpotlightSearchTool is built for documents, not devices.** We measured what it sends the model:
  - Its default guidance is about 13,000 tokens, roughly three times the on-device context.
  - Its focused guidance fits, but only offers document fields (email, pdf, sender, recipient, dates).
  - Our custom `deviceStatus` stage never appears in the focused schema, so "which lights are on?" can't be answered on device.
- **Our engine already answers what the model needs.** On the golden set it gets 361 of 380 queries right, where Spotlight's query API gets 65. It also handles typos, meaning, rooms, exclusions, live status and personal names, which Spotlight doesn't hold.
- **Using both.** The tools complement each other only when Spotlight holds content that isn't a device (history, manuals, media). Route each question in code to the tool that owns its content, and use both in one session only for mixed questions (Part 4).
- **Proposal.** Add `DeviceSearchTool`, a tool that mirrors `SpotlightSearchTool`'s shape (configuration, guidance levels, a `searchResults` stream, custom stages).
  - The model passes the person's device words and optional filters, and the engine does the searching.
  - The model-facing contract fits in about 200 tokens, and the tool works on iOS 26 and 27.
  - The Ask tab moves to it, with `SpotlightSearchTool` kept behind a flag for comparison.

---

## Part 1: How Foundation Models tools are meant to be used

### The protocol

From the iOS 27 SDK (`FoundationModels.swiftinterface`):

```swift
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public protocol Tool<Arguments, Output>: Sendable {
    associatedtype Output: PromptRepresentable
    associatedtype Arguments: ConvertibleFromGeneratedContent
    var name: String { get }                         // default: the type name
    var description: String { get }
    var parameters: GenerationSchema { get }         // derived when Arguments is @Generable
    var includesSchemaInInstructions: Bool { get }   // default true
    @concurrent func call(arguments: Arguments) async throws -> Output
}
```

- `Arguments` is normally a `@Generable` struct, so the model fills it by guided generation and can't produce malformed input. A plain `String` or `Int` is rejected at compile time.
- `Output` can be a `String`, `GeneratedContent` or any `@Generable` type.
- The tool must be `Sendable`. `call` may run **concurrently with itself and with other tools**, because the model can call a tool several times in parallel ("compare Boston and Wichita").

### How a request flows

Apple describes the flow in six phases, from the [tool calling article](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling):

1. The app creates a session with tools and sends a prompt.
2. The model decides whether a tool would help.
3. If so, it generates arguments that match the tool's schema.
4. The framework runs `call(arguments:)`.
5. The output is appended to the transcript.
6. The model writes its answer from that output.

### Apple's guidance

From [Expanding generation with tool calling](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling) and [Managing the context window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window):

| Topic | Guidance |
|---|---|
| Context | The on-device model has **4,096 tokens per session**. Prompts, instructions, tool definitions, arguments, tool output, schemas and responses all count. About 3–4 characters per token in English. |
| Descriptions | "Limit tool descriptions and `@Guide` annotations to short phrases." The model reads them to decide when to call. |
| Argument types | Keep generable types simple, with clear property names. Add `@Guide` only where a name isn't enough, and use ranges or counts to bound values. |
| Number of tools | "No more than three to five tools per request." |
| When not to use a tool | "If the model always needs specific information, retrieve it directly and include it in your prompt rather than relying on tool calling." |
| Big tasks | Split across sessions, so each gets a fresh context window. Generate arguments in one session, run the tool in code, process the output in another. |
| Forcing a call (iOS 27) | `GenerationOptions(toolCallingMode: .required)` makes the model call a tool before answering. You **must** give it an exit condition: throw from the tool, or switch to `.allowed` after the first call with a `DynamicProfile` (`.onToolCall { count += 1 }`). Otherwise the model keeps calling. `.disallowed` answers from what's already in the session. |
| Errors | Throwing from `call` surfaces as `LanguageModelSession.ToolCallError`, which carries the tool and the underlying error. The transcript rolls back unless `transcriptErrorHandlingPolicy(.preserveTranscript)` is set. Alternatively, return a short string such as "Cannot access the database." so the model can explain. |
| Debugging | `session.transcript` exposes `.toolCalls` and `.toolOutput` entries. The Foundation Models template in Instruments shows tokens per prompt, response and tool call. |
| Measuring tokens | `SystemLanguageModel.tokenCount(for:)` takes prompts, instructions, **tools**, schemas or transcript entries, and `contextSize` gives the limit (iOS 26.4+). |

### What iOS 27 adds around tools

- `GenerationOptions.ToolCallingMode`: `.allowed` (the default), `.required` and `.disallowed`.
- `LanguageModelSession.DynamicProfile`:
  - The `Profile { tools… }` builder.
  - Modifiers: `.toolCallingMode(_:)`, `.onToolCall`, `.onToolOutput`, `.onPrompt`, `.onResponse`, `.transcriptErrorHandlingPolicy(_:)`.
  - `@SessionProperty` for state across turns.
- `LanguageModelError.contextSizeExceeded(_:)`, which replaces `GenerationError.exceededContextWindowSize`.
- `PrivateCloudComputeLanguageModel`, a larger server model with its own context size and quota. This is relevant because Apple says `SpotlightSearchTool`'s default guidance "works best with Private Cloud Compute (PCC) models".
- System tools: `SpotlightSearchTool`, `OCRTool` and `BarcodeReaderTool`.

---

## Part 2: SpotlightSearchTool analysis

### What it is

`SpotlightSearchTool` (module `_CoreSpotlight_FoundationModels`, iOS/iPadOS/macOS/visionOS 27) is a ready-made `Tool`:
- The model writes a Spotlight query.
- Spotlight runs it over the app's Core Spotlight index (or its files).
- The model answers from the returned items.

Apple's [WWDC26 session 246](https://developer.apple.com/videos/play/wwdc2026/246/) sums it up: "We're not writing search queries anymore. We're providing the content, and letting intelligence do the rest."

### Configuration surface

| Piece | What it does |
|---|---|
| `Configuration(sources:guide:contactResolver:customStages:)` | Everything below. |
| `sources` | `.coreSpotlight(CoreSpotlightSource)` or `.files`. `CoreSpotlightSource` sets `fetchAttributes`, `maximumResultCount`, `sourceOptions` and a `searchableIndexDelegate`. |
| `guide.level` | `.complete` (the default, the full query language), `.focused(ContentDomain)` (a small schema for one domain: `.items`, `.documents`, `.communications`, `.calendar`, `.audio`, `.visualMedia`, each with attribute mappings), or `.dynamic(GuidanceProfile)` (switch text match, similarity, numeric, dates, people and content type on or off, and list attributes). |
| `guide.format` | `.structured` or `.compact`: how replies are serialized into the model's context. |
| `customStages` | `@Generable` types conforming to `CustomStage`. They declare `inputTypes` and `outputTypes` (`items`, `scoredItems`, `groupedItems`, `count`, `table`, `statistic`, `text`) and implement `execute(…)`. |
| `contactResolver` | Maps "me" and household names onto indexed people. |
| `searchResults` | An `AsyncSequence<SearchReply, Never>`. Each reply has `content` (items, scored items, groups, count, table, statistic or text), `label` (written by the model), `queryToken` (one per search), `stageToken` and `status` (`.partial` or `.complete`). It's for list-style UI next to the model's prose answer. |
| `Arguments` | `GeneratedContent`. The schema is built at run time from the configuration ("RAGSearchArguments" when focused, "FullArguments" when complete). |
| Hydration | Compact stored fields (text content, HTML) are unreadable by the model, so the tool asks the index delegate's `searchableItems(forIdentifiers:)` for full items. |

### How Apple says to use it

From [WWDC26 246](https://developer.apple.com/videos/play/wwdc2026/246/) and the [`SpotlightSearchTool` reference](https://developer.apple.com/documentation/corespotlight/spotlightsearchtool):

1. Donate good content to Core Spotlight first.
2. Create the tool, add it to a `LanguageModelSession`, and prompt.
3. "Always configure `SpotlightSearchTool` with a guide that works well with a model's context window to avoid token overflow errors." On-device models should use `.focused` or a narrow `GuidanceProfile`.
4. Implement the index delegate so the model reads full items.
5. Show `searchResults` in lists, and start a new section on each new `queryToken`, since one answer can search several times.
6. Add custom stages for computation the model can't do well itself.
7. Measure with the Evaluations framework, for example `ToolExpectation("searchSpotlight", arguments: [.keyOnly(argumentName: "query")])` with a `ResultCoverage` metric.

### What we measured

We dumped the tool's model-facing `description` and `parameters` in the iOS 27 simulator (temporary hook, since removed):

| Configuration | Description | Argument schema (JSON) | Rough tokens* |
|---|---|---|---|
| Default (`.complete`) | 4,301 chars | 47,595 chars | ~13,000 |
| `.dynamic` profile (text and dates only, 2 attributes) | 4,068 chars | 47,595 chars | ~13,000 |
| `.focused(.items(…))`, `.compact` | 107 chars | 845 chars | ~270 |
| Same, plus our `deviceStatus` custom stage | 107 chars | 845 chars (unchanged) | ~270 |

\*At 3.5 characters per token. This is an estimate; `tokenCount(for: [tool])` gives the real number on a device.

Findings:

1. **Only focused guidance fits on device.** Complete or dynamic guidance alone is about three times the 4,096-token context, which matches Apple's note that the default suits PCC.
2. **Focused guidance is a document search.** The whole schema is: `contentTypes` (email, pdf, image, music, meeting, calendar, contact, document), `searchTerms`, `queriedSender`, `queriedRecipient`, `on`, `after`, `before`, `similarTo`, `limit` and `label`.
   - The attribute mapping we passed (`title`, `text`, `modified`) doesn't change the schema.
   - There is no field for room, type, brand or state.
3. **Custom stages don't reach the model in focused mode.** The schema has no pipeline at all, so our `LiveStatusStage` is dead code on device.
   - Complete mode has a generic `Custom` stage kind with a free-text `stageType`.
   - Our stage's name and description appear nowhere in what the model receives.
   - So we couldn't confirm the model could pick it even there.
4. **The description embeds today's date** ("Today: 2026-11-05"), so the tool definition changes daily.
5. **Retrieval is Spotlight's.** Matching is keyword and date based over the donated attributes.
   - In our comparison, Spotlight's in-app query API answered 65 of 380 golden queries.
   - It has no typo tolerance beyond prefixes, and no device-type meaning, exclusions or live status.

### Fit for a smart-home app

| Need | SpotlightSearchTool | Our engine |
|---|---|---|
| Runs on iOS 26 | No (iOS 27) | Yes (`Tool` is iOS 26) |
| Fits the on-device context | Only in focused mode | Yes: ~200-token contract (to verify) |
| Room, type, brand understanding | Free text only | Parsed into entities and facet filters |
| Typos ("bedrom ac") | Prefix only | Edit distance, phonetic, word split, suffix |
| Meaning ("something to cool the bedroom") | `similarTo`, Spotlight's own semantics | Concept routing to device types, plus a semantic list |
| Exclusions ("except kitchen") | No | Yes |
| Live state (on, off, online, offline) | Not in the index. The custom stage isn't reachable on device. | In every record, updated through the fast path |
| Learned nicknames, usage | No | Yes (personalisation) |
| Sensitive devices | Whatever was donated | Same rules as in-app search |
| Counting and grouping | Pipeline stages, complete mode only | `SetSummary` already counts by type and room |
| Results for list UI | `searchResults` stream | Same shape (proposed) |
| Testable without a model | No | Yes: call `call(arguments:)` directly |

`SpotlightSearchTool` remains the right tool for content we don't own in-app, such as files, or when running on PCC. For devices, our engine is the better retriever, and the tool only needs to expose it compactly.

---

## Part 3: DeviceSearchTool design

### Goals

- The same usage pattern as `SpotlightSearchTool`: create, configure, add to a session, read `searchResults`.
- Fit comfortably in the on-device context: definition under ~250 tokens, output under ~200 tokens per call.
- Work on iOS 26.0+ wherever Apple Intelligence is available. Use iOS 27 extras (`toolCallingMode`, `DynamicProfile`) behind `#available`.
- Read-only. Never changes a device.
- Deterministic and unit-testable without a model.

### Non-goals

- Device control from the model. Switching stays with the confirmed command path and the App Intents. A later `ControlDevicesTool` could return a *pending* command for the UI to confirm, but never act itself.
- Replacing in-app search. A typed search keeps the three-phase engine with no tool and no session.
- Content outside devices (files, notes). That stays with `SpotlightSearchTool`.

### Public API

The shape mirrors `SpotlightSearchTool` so the two are interchangeable in `DeviceAsk`:

```swift
import FoundationModels
import SearchCore
import DeviceSearch

@available(iOS 26.0, macOS 26.0, *)
public struct DeviceSearchTool: Tool {
    public let name = "searchDevices"
    public var description: String { configuration.guide.description }

    public let configuration: Configuration
    /// Every search the model runs, for list-style UI (same role as `SpotlightSearchTool.searchResults`).
    public var searchResults: some AsyncSequence<SearchReply, Never> { hub.replies() }

    public init(engine: SearchEngine, configuration: Configuration = .init())

    public typealias Arguments = GeneratedContent        // schema depends on the guide level
    public var parameters: GenerationSchema { configuration.guide.schema(for: snapshot) }
    @concurrent public func call(arguments: GeneratedContent) async throws -> String
}

extension DeviceSearchTool {
    public struct Configuration: Sendable {
        public var guide: Guide = .init()
        public var maximumResults = 8                     // rows written into the model's context
        public var customStages: [any DeviceSearchStage] = []
        public init(guide: Guide = .init(), maximumResults: Int = 8, customStages: [any DeviceSearchStage] = [])
    }

    public struct Guide: Sendable {
        public var level: GuidanceLevel = .focused
        public var format: FormatLevel = .compact
    }

    public enum GuidanceLevel: Sendable {
        case minimal      // query only: smallest contract, the engine parses everything
        case focused      // query + state + answer + limit (default)
        case homeAware    // focused + this home's rooms and device types as enums (constrained decoding)
    }

    public enum FormatLevel: Sendable { case compact, structured }

    public struct SearchReply: Sendable {
        public enum Content: Sendable {
            case devices([SearchResult])                  // ranked, best first
            case count(Int, byRoom: [String: Int])
            case none(message: String)                    // nothing matched, with what was relaxed
        }
        public let content: Content
        public let label: String?                         // the model's short label, if it gave one
        public let queryToken: QueryToken                 // one per call(arguments:)
        public let query: ParsedQuery                     // what the engine understood (for chips and debugging)
    }
}
```

`Arguments = GeneratedContent` follows `SpotlightSearchTool`: the schema is built at run time. That lets `.homeAware` put the current home's room and type names into the schema as enums, so the model **cannot** invent a room. The `minimal` and `focused` levels can use a static `@Generable` struct internally.

### What the model sees

**Name:** `searchDevices`, following Apple's examples (`searchBreadDatabase`, `findPointsOfInterest`).

**Description** (one short phrase, about 15 tokens):

> Finds devices in this home by name, type, room, brand or current state.

**Arguments, focused level** (the default):

```swift
@Generable
struct FocusedArguments {
    @Guide(description: "Device words from the request, like \"bedroom lights\" or \"something to cool the kitchen\"")
    var query: String
    var state: DeviceStateFilter?        // @Generable enum: on, off, online, offline
    var answer: AnswerKind?              // @Generable enum: list, count
    @Guide(.range(1...8))
    var limit: Int?
}
```

- `query` carries the person's own words. The engine's parser handles typos, rooms, types, brands, exclusions and meaning, so the model doesn't have to decompose the request. That is where small models make most mistakes.
- `state` is separate because "on" and "off" are ambiguous inside free text: "turn on" is an action, not a filter. A typed enum makes it exact.
- `answer: .count` answers "how many…" without listing every device.
- Estimated size: ~550 characters of schema (~160 tokens), plus the description. To be verified with `tokenCount(for:)`.

**Minimal level:** only `query`. About 60 tokens. For sessions that already use other tools.

**Home-aware level:** adds `room: Room?` and `type: DeviceType?` as enums of this home's rooms (26 in the sample home) and device types (~40). About 300 more tokens. Use it when a measured accuracy gain justifies the cost.

### What a call does

```
call(arguments)
 1. Decode arguments (GeneratedContent → FocusedArguments). Clamp limit to 1…maximumResults.
 2. Search: engine.searchAll(query, mode: .submitted,
                             options: SearchOptions(allowRefinement: false))   // no nested model call
    → take the last phase (hybrid when meaning is on, else instant).
 3. Filter: keep results whose device.status matches `state` (v1: post-filter on the full result set;
    v2: pass it into the parsed query as a hard filter, so relaxation and the set summary agree).
 4. Run custom stages in registration order (see below).
 5. Publish a SearchReply on the hub (with a new queryToken).
 6. Return compact text for the model (below).
```

- **No nested model call.** `allowRefinement: false` keeps the engine's own re-ranker out of it. The outer session is already the model, and a second concurrent Foundation Models request fails with `concurrentRequests`.
- **Speed.** A search takes 2–10 ms on the 500-device home (debug build, Mac), so the model's generation dominates.

### What the model gets back

Compact text, one line per device, ordinal-numbered so the model can refer to rows. IDs stay out of the model's context: the app gets them from `searchResults`, and leaving them out saves tokens and stops the model from inventing IDs.

```
8 devices match "bedroom lights" (showing 5):
1. Bedroom Light · Bedroom · light · on
2. Bedroom Lamp · Bedroom · lamp · off
3. Bedside Lamp · Bedroom · lamp · offline
4. Master Bedroom Light · Master Bedroom · light · on
5. Bedroom Ceiling Fan Light · Bedroom · light · off
```

```
Lights that are on: 14 (Kitchen 3, Living Room 3, Bedroom 2, 6 other rooms).
```

```
No devices match "garage heater". Closest: Garage Fan · Garage · fan (type relaxed).
```

- Roughly 10–12 tokens per row, so 8 rows plus a header is about 110 tokens.
- With `.structured` format the tool returns a `@Generable` value instead, for apps that prefer typed transcript entries.
- When nothing matches, the tool **returns a short message rather than throwing**, as Apple suggests. The model can then say so, and the transcript isn't rolled back.

### Custom stages

These are the counterpart of `CustomStage`, but kept small so they actually reach an on-device model:

```swift
public protocol DeviceSearchStage: Sendable {
    /// One word the model can pick, like "unusedSince".
    static var name: String { get }
    /// A short phrase, shown to the model as an enum case description.
    static var description: String { get }
    func apply(_ results: [SearchResult]) async -> [SearchResult]
}
```

- Registered stages appear as one optional enum argument, `refine: RefineKind?`, so each one costs a few tokens, not a schema section.
- Examples: `notUsedThisWeek` (from `usage.lastUsedAt`), `favorites`, and `batteryLow` once status carries battery.
- Live on/off/online/offline doesn't need a stage: it's the built-in `state` argument.

### Concurrency and lifetime

- `DeviceSearchTool` is a `Sendable` struct. It holds the `SearchEngine` (an actor) and a `ReplyHub`, a `final class … Sendable` with a `Mutex`-guarded list of continuations (the pattern of `SearchEngine.snapshotUpdates()`).
- `call` is `@concurrent` and stateless apart from publishing to the hub, so parallel calls are safe.
- Each call gets its own `queryToken`. The UI starts a new section per token, as Apple recommends for `SpotlightSearchTool`.
- The tool reads whatever snapshot the engine holds when the call runs. Device changes during an answer show up in the next call.

### Session recipe

```swift
let tool = DeviceSearchTool(engine: home.engine)
let session = LanguageModelSession(
    model: .default,
    tools: [tool],
    instructions: "Answer questions about the devices in this home. Search before answering. Use one or two short sentences and name the devices.")

// iOS 27: guarantee one search, then let the model answer (Apple's exit-condition pattern).
let options: GenerationOptions
if #available(iOS 27.0, *) { options = GenerationOptions(toolCallingMode: .required) } else { options = GenerationOptions() }
let answer = try await session.respond(to: question, options: options)
```

With `.required`, add the exit condition Apple requires: a `DynamicProfile` that switches to `.allowed` after the first `onToolCall`. On iOS 26 the instruction "Search before answering" is the only lever, so check `session.transcript` for a `.toolCalls` entry and fall back to the engine's own list when it's missing.

Rules for `DeviceAsk`:
- One session per question.
- Instructions under three sentences.
- Only this tool, unless a second one is clearly needed. Apple's limit is three to five.
- Call `prewarm()` when the Ask tab appears.

### Route before you ask

Apple: "Skip tool calling when you don't need the model to make decisions." Most device requests don't need it:

| Query kind (engine's intent) | Path |
|---|---|
| Navigational ("bedroom ac"), categorical ("offline cameras"), command | The engine's list directly. No session. |
| Descriptive ("something to cool the bedroom") | The engine's hybrid phase is usually enough. Use the model only for a sentence answer. |
| Questions ("which lights are still on downstairs?", "how many cameras are offline?", "what did I use today?") | Session + `DeviceSearchTool`. |

`DeviceAsk` runs the parser first, costing under a millisecond, and opens a session only for question-like input.

### Errors and edge cases

| Case | Behaviour |
|---|---|
| No active home | Throw `DeviceSearchToolError.noHome` → `ToolCallError` → "Open a home first." |
| Nothing matches | Return a "No devices match…" line (with what the ladder relaxed). Don't throw. |
| Too many matches | Return the count, the top `limit` rows and the room breakdown. Never more than `maximumResults` rows. |
| Model passes an empty query with a state | Search all devices with the state filter ("anything offline?"). |
| Context exceeded | Catch `LanguageModelError.contextSizeExceeded` and retry once in a fresh session with the minimal level. |
| Model unavailable | `DeviceAsk` shows the engine's results with a note. The tool itself never needs the model. |

### Privacy and safety

- Everything stays on device with `SystemLanguageModel`. If PCC is ever used, device names and rooms leave the device, which needs its own privacy review and a user-facing setting.
- Read-only by construction: the tool has no access to `DeviceControl`.
- Sensitive types (locks, cameras, doorbells, garage doors) are listed, as in-app search lists them, but their state wording stays neutral ("online"), with no "unlocked".
- Device names are user text going into a prompt. Output lines are plain data and not instructions, and the session instructions say to answer only about devices.

### Availability

| Feature | Needs |
|---|---|
| `DeviceSearchTool`, sessions, `@Generable` arguments | iOS 26.0 + Apple Intelligence |
| `tokenCount(for:)`, `contextSize` (budget checks in tests and debug) | iOS 26.4 |
| `toolCallingMode`, `DynamicProfile`, `onToolCall` | iOS 27 (`#available`) |
| `SpotlightSearchTool` comparison path | iOS 27, arm64 |

---

## Part 4: Using DeviceSearchTool together with SpotlightSearchTool

### The starting point

Four facts decide how the two tools can work together:

1. **They read the same devices today.** `SpotlightIndexer` donates only device items, so `SpotlightSearchTool` can only find devices, and it finds them less well than our engine. It knows nothing about live state, and its focused schema has no room or type fields.
2. **The Spotlight tool can't be scoped.** `CoreSpotlightSource` takes fetch attributes, a result cap, source options (only "allow mail") and a hydration delegate, but no filter query. It always sees everything the app has indexed.
3. **Their descriptions are distinct.** Ours reads "Finds devices in this home…". Spotlight's focused description reads "Search for documents and files." Its `name` is a settable property (default `spotlight_search`), but its `description` can't be changed.
4. **Two definitions fit on device.** Focused Spotlight (~270 tokens, measured) plus ours (~200, estimated) is about 470 of 4,096 tokens, within Apple's limit of three to five tools. Complete Spotlight (~13,000) never fits.

So the combination only pays off once the app indexes **content that isn't a device**. Until then, a second tool adds duplicates and a chance for the model to pick the weaker search, with nothing to gain.

### Split the content by what each search is good at

| Content | Best search | Why |
|---|---|---|
| Devices: names, rooms, types, brands, on/off, online/offline, nicknames, usage | **DeviceSearchTool** | Parsed entities, typo and meaning handling, live status, personal signals |
| Scenes and automations ("Good night", "Away mode") | **DeviceSearchTool** (as engine documents) | Short names searched like devices. The model may want to list or count them. |
| Device history: "front door opened 07:42", "motion in garage", "AC turned off by schedule" | **SpotlightSearchTool** | Dated items. The focused schema already has `on`, `after` and `before`. |
| Manuals, warranties, receipts, energy reports (PDFs in the app sandbox) | **SpotlightSearchTool** with `.files` or indexed items | Body text and documents, which is the tool's home ground |
| Camera snapshots and clips | **SpotlightSearchTool** (`visualMedia` domain), in the protected index | Media with dates. Sensitive, so in the `.complete` protection class. |
| Support chats, notes on a device | **SpotlightSearchTool** | Free text with dates |

Each non-device item carries the device it belongs to in a custom attribute (a `deviceID` key, like the existing `typeKey`). Results from the two tools can then be joined in code. Devices stay in the Spotlight index, because system Spotlight and Siri use it, but in-app answers about devices always come from our engine.

### Patterns, best first

**1. Route in code, one tool per session (the default).** The parser runs first, in under a millisecond. Then:

| Question | Route | Tools in the session |
|---|---|---|
| A device search ("bedroom ac", "offline cameras") | Engine list, no session | none |
| A device question ("which lights are still on?", "how many cameras are offline?") | Session | DeviceSearchTool |
| A content question ("when did the front door open yesterday?", "find the dishwasher manual") | Session | SpotlightSearchTool (focused) |
| Mixed ("is the garage light still on, and when did the garage door last open?") | Session, or the chain below | both |

- Apple's guidance supports this: give each request only the tools it needs, and skip tools when code can decide.
- Content questions are recognised by cues our knowledge base can hold: time words (yesterday, last week, when), history verbs (opened, triggered, happened), and document words (manual, warranty, receipt, report).

**2. Both tools in one session, for mixed questions.**

```swift
let session = LanguageModelSession(
    model: .default,
    tools: [deviceTool, spotlightTool],          // spotlightTool: .focused(.items(…)), .compact
    instructions: """
        Answer about this home. Use searchDevices for devices and what they are doing now. \
        Use spotlight_search for past events, manuals and documents. Keep answers short.
        """)
```

- On iOS 27, use `toolCallingMode(.required)` with a `DynamicProfile` that switches to `.allowed` after two calls. Apple requires that exit condition.
- Expect the small model to sometimes call only one tool. Check `session.transcript` and run the missing search in code when a cue says it was needed.

**3. Chain in code, for questions that depend on a device.**
- Apple's pattern for tight contexts is to generate arguments in one step, run the tool in code, then process the output.
- For "find the manual for the bedroom AC":
  1. The engine resolves "bedroom AC" to Bedroom AC (Samsung).
  2. The Spotlight search runs with "Samsung" and the model name as search terms, or filtered by `deviceID`.
  3. A fresh session writes the answer from both outputs.
- This is deterministic where it matters (which device) and leaves the model only the writing.

**4. Merge both result streams into one view.**
- `DeviceAsk` listens to both `searchResults` streams and starts a section per `queryToken`: "Devices" for ours, "History and documents" for Spotlight.
- Any Spotlight item that is a device (`SpotlightItemMapping.deviceID(fromIdentifier:)` succeeds) moves into the device section, shown from our engine's record so its state is live, or is dropped as a duplicate.

### What to avoid

| Anti-pattern | Why |
|---|---|
| Giving the model both tools while the index holds only devices | Duplicate results and a 50/50 tool choice, with no new information. This is the situation today. |
| Falling back to SpotlightSearchTool when ours finds no device | Both read the same devices, and Spotlight's matching is weaker (65/380 vs 361/380). Use the engine's own relaxation ladder instead. |
| Complete or dynamic Spotlight guidance on device | ~13,000 tokens, about three times the context. Only reasonable on Private Cloud Compute, after a privacy review. |
| Spotlight custom stages for live state | They don't reach the model in focused mode (measured). Live state belongs to our tool's `state` argument. |
| One tool calling the other, or a session inside a tool | It nests model requests (`concurrentRequests` failures) and hides the call graph from the transcript. |
| Returning device IDs to the model from either tool | They cost tokens and can be invented. Keep IDs in the result streams for the app. |

### By platform

| Platform | Setup |
|---|---|
| iOS 26 | DeviceSearchTool only (SpotlightSearchTool doesn't exist). Content questions get "not available yet". |
| iOS 27, on-device model | Routing as above. Spotlight always `.focused`, `.compact`, with `maximumResultCount` around 10–20 to bound its output. |
| iOS 27, Private Cloud Compute (optional) | Complete Spotlight guidance with pipeline stages fits PCC's larger context. Device names, rooms and history then leave the device, so this needs a privacy review and a user setting first. |

### Cost of a mixed answer on device

These are estimates, to confirm with `tokenCount(for:)` and the Foundation Models instrument:

| Part | Tokens |
|---|---|
| Instructions | ~50 |
| DeviceSearchTool definition | ~200 |
| SpotlightSearchTool definition (focused) | ~270 (measured from characters) |
| Question | ~20 |
| DeviceSearchTool output (8 rows) | ~110 |
| SpotlightSearchTool output (10 compact items) | ~300–600 (to measure; depends on the fetched attributes) |
| Answer | ~60 |
| **Total for one call each** | **~1,000–1,300 of 4,096** |

There is room for a second call each, but not for long-running conversations. Keep one session per question.

### Measuring the combination

Add to the evaluation in Part 6:
- A mixed-question golden set: device, content and mixed questions, each with the expected tool or tools and the expected items.
- **Tool-selection accuracy**, from `.toolCalls` entries in the transcript. With the Evaluations framework, use `ToolExpectation("searchDevices", …)` and `ToolExpectation("spotlight_search", …)`.
- Coverage per tool, duplicates removed by the merge, tokens per answer, and latency.
- The routed setup (pattern 1) against both tools in every session (pattern 2). Keep pattern 2 only where it wins.

## Part 5: Integration plan

| Change | Where |
|---|---|
| New package target `SearchTool` (depends on `DeviceSearch`; `#if canImport(FoundationModels)`) with `DeviceSearchTool`, `ReplyHub`, the argument types, the output formatter and `DeviceSearchStage` | `DeviceSearch/Sources/SearchTool/` |
| Test target `SearchToolTests` | `DeviceSearch/Tests/SearchToolTests/` |
| Feature flag `modelToolEnabled` (kill switch, like the others) | `SearchCore/FeatureFlags.swift` |
| `DeviceAsk` uses `DeviceSearchTool` by default and the parser-first router. `SpotlightSearchTool` stays behind a debug setting for A/B. The dead `LiveStatusStage` is removed. | `AppTarget/DeviceSearch/DeviceAsk.swift` |
| Ask tab available on iOS 26 too, with sections per `queryToken` and the parsed-query chips | `DemoApp/DeviceSearchDemo/AskView.swift` |
| Comparison harness gets a third column: `DeviceSearchTool` | `DemoApp/DeviceSearchDemo/SpotlightComparison.swift` |

---

## Part 6: Testing and evaluation

1. **Unit tests (no model).** Call `call(arguments:)` directly on the 500-device home and check:
   - Rows and order for golden queries.
   - The `state` filter.
   - `count` answers.
   - The empty and relaxed messages.
   - Output length stays under budget (characters, and `tokenCount` where available).
   - Parallel calls get distinct `queryToken`s.
2. **Schema budget test.** Assert the tool definition stays under 250 estimated tokens, and the real `tokenCount(for: [tool])` on a device.
3. **Golden set through the model** (device, Apple Intelligence). For each golden query, ask the session and record:
   - whether the tool was called (transcript)
   - the arguments it generated
   - coverage, meaning the share of expected devices that appear in `searchResults`
   - latency.

   Compare against the same run with `SpotlightSearchTool` (focused), using the existing harness.
4. **Evaluations framework (iOS 27).** `ToolExpectation("searchDevices", arguments: [.keyOnly(argumentName: "query")])` plus a `ResultCoverage` metric, as in WWDC26 246.
5. **Instruments.** The Foundation Models template on a device, to confirm the token use per call.

---

## Part 7: Rollout

| Milestone | Scope | Gate |
|---|---|---|
| T1 | `SearchTool` target: focused level, compact output, the `state` filter, `ReplyHub`, unit tests | Unit tests pass. Definition ≤ 250 tokens. Output ≤ 200 tokens per call. |
| T2 | `DeviceAsk` on `DeviceSearchTool` with the router. Ask tab on iOS 26. iOS 27 `.required` + exit condition. | On device, the tool is called for ≥ 95 % of question-like golden queries. Coverage beats `SpotlightSearchTool` focused. |
| T3 | Custom stages (`notUsedThisWeek`, `favorites`). `.homeAware` level behind a flag. `.structured` format. | Home-aware improves coverage enough to justify ~300 tokens. Decided from the T2 numbers. |
| T4 | Optional `ControlDevicesTool` that returns a pending command for UI confirmation | Separate design and safety review. |
| T5 | Combined Ask on iOS 27 (Part 4): content routing, both tools for mixed questions, merged result streams | Starts only after the app indexes non-device content (history, manuals). Routed setup must match or beat device-only on device questions. |

## Open questions

1. Does the on-device model reliably fill `state` from "still on" or "left on"? T2 will tell. If not, the engine can extract it from `query` as it does for "offline".
2. Is the home-aware level worth ~300 tokens? It removes invented rooms, but the parser already maps unknown room words to the closest real room or relaxes the filter.
3. Should the tool's text include the room breakdown for every list, or only for count answers? This is a token trade-off to measure.
4. Which non-device content is worth indexing first for the Spotlight side: event history, manuals or camera snapshots? This decides when T5 is worth starting.
5. Can we confirm whether `SpotlightSearchTool` exposes custom stages in complete mode on PCC? This only matters if we ever use PCC.

## Sources

- SDK interfaces, Xcode-beta iOS 27.0: `FoundationModels.swiftinterface` (`Tool`, `GenerationOptions.ToolCallingMode`, `DynamicProfile`, `tokenCount(for:)`, `PrivateCloudComputeLanguageModel`) and `_CoreSpotlight_FoundationModels.swiftinterface` (`SpotlightSearchTool`, `CustomStage`, `SearchReply`).
- [Expanding generation with tool calling](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling), Apple
- [Managing the context window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window), Apple
- [SpotlightSearchTool](https://developer.apple.com/documentation/corespotlight/spotlightsearchtool), Apple
- [LLM search using Core Spotlight, WWDC26 session 246](https://developer.apple.com/videos/play/wwdc2026/246/)
- [What's new in the Foundation Models framework, WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/)
- [Foundation Models in iOS 27: Tool-Calling Control](https://blakecrosley.com/blog/foundation-models-tool-calling-ios-27), Blake Crosley
- [Foundation Models, Year Two](https://ivanmagda.dev/posts/wwdc26-foundation-models-year-two/), Ivan Magda
- This repository: the schema dump (described in Part 2), `DemoApp/DeviceSearchDemo/SpotlightComparison.swift` (361/380 vs 65/380), and the engine trace behind the architecture page.
