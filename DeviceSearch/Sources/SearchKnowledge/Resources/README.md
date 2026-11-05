# Knowledge base

The data `KnowledgeBase` loads at startup. Each file has a `version` number; bump it when the shape changes.

- `types.json`: device types with their labels, codes, synonyms, descriptions and concept weights.
- `brands.json`: brands and the aliases people use for them.
- `rooms.json`: room names, aliases, translations (`localized`) and concept weights.
- `lexicon.json`: status phrases, negations, quantifiers, room prepositions and generic nouns the parser understands.

Add a synonym or alias here, not in code. `KnowledgeBaseTests` checks that the files load and every type is well formed.
