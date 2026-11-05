# Contributing

Thanks for helping. Bug reports, search misses, new synonyms and code are all welcome.

## Before you start

- For anything bigger than a small fix, open an issue first so we can agree on the approach.
- Read [ArchitectureDiagram.md](ArchitectureDiagram.md). Each module depends only on the layers beneath it; keep it that way.
- Be kind. This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Setup

You need macOS 26 and Xcode 26.4 or later for the package. The demo app's iOS 27 features need Xcode 27.

```bash
git clone https://github.com/ksypinro/DeviceSearch.git
cd DeviceSearch/DeviceSearch
swift build
swift test
```

The demo app is in `DemoApp/DeviceSearchDemo.xcodeproj`; see [DemoApp/README.md](DemoApp/README.md).

## Making a change

1. Branch from `main`.
2. Add or update tests next to the module you change (`DeviceSearch/Tests/<Module>Tests`). The suite uses Swift Testing (`@Test`).
3. If the change can affect ranking, run the evaluation tests (`swift test --filter SearchEvaluationTests`) and put the before and after numbers in the pull request.
4. Keep tunable numbers in `SearchConfig`, and words (synonyms, brands, rooms, phrases) in the JSON files under `Sources/SearchKnowledge/Resources`, not in code.
5. Run `swift test` and make sure it passes.
6. Open a pull request and fill in the template.

## Reporting a search miss

The most useful report is a query, the devices in the home (names, rooms and types are enough), what you expected and what you got. The issue template "Search miss" asks for exactly that.

## Style

- Swift 6 language mode, strict concurrency. Engine types are `Sendable`; shared state lives in actors.
- Follow the style of the surrounding code. Doc comments say what a type is for and why; skip the obvious.
- No new third-party dependencies without discussing them in an issue first. The package depends only on Apple frameworks.
- Nothing leaves the device. Don't add network calls to the package.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
