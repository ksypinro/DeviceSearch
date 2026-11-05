# Golden queries

Hand-written queries the evaluation runs on top of the generated golden set (`GoldenSetBuilder`).

- `golden-descriptive.json`: descriptive searches ("something to cool the bedroom") with the device types that should rank first (`primary`) and those that may follow (`secondary`).
- `golden-multilingual.json`: searches in other languages and scripts.

Each entry has `text`, `category`, `primary`, `secondary`, an optional `room`, and `expect` (`set` for an exact set, `graded` for a ranked one).
