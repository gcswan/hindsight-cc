---
description: Search your project's memory bank for relevant context
allowed-tools: Bash
---

# Search Memory

Search the Hindsight memory bank for context relevant to a query.

## How memory search works

memory-search passes a memory bank id and a query to `Hindsight.recall()`

Recall performs 4 retrieval strategies in parallel:

- Semantic: Vector similarity
- Keyword: BM25 exact matching
- Graph: Entity/temporal/causal links
- Temporal: Time range filtering

The individual results from the retrievals are merged, then ordered by relevance using reciprocal rank fusion and a cross-encoder reranking model.

The final output is trimmed as needed to fit within the token limit.

### Output Format

#### When memories are found

```text
Found 3 relevant memories:

--- Memory 1 ---
User asked about implementing JWT authentication...

--- Memory 2 ---
Discussion about OAuth2 token refresh...
```

#### When no memories match

```text
No relevant memories found.
```
