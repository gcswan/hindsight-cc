---
description: Reflect on technical decisions and past context when confidence is low. Use when uncertain about implementation approaches, architectural choices, or need deeper analysis before proceeding.
allowed-tools: Bash
argument-hint: <query> [--budget <level>] [--context <text>] [--max-tokens <int>]
---

# Hindsight Reflection Skill

## When to Use This Skill

Use this skill autonomously when:

- You have low confidence about a technical decision
- Multiple implementation approaches seem viable and need evaluation
- You need to reflect on past context before committing to significant architectural choices
- A design decision requires deeper analysis or validation
- You want to explore trade-offs between different approaches

This skill uses Hindsight's reflection capabilities to provide AI-assisted decision support by analyzing past context and generating insights.

## How to Execute

Run the following command with your reflection query. You can optionally specify budget level, additional context, and token limits for more comprehensive analysis.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/.venv/bin/python3 ${CLAUDE_PLUGIN_ROOT}/scripts/reflect.py $ARGUMENTS
```

### Parameters

- **query** (required): The question or decision to reflect upon
- **--budget** (optional): Budget level - "low", "mid", or "high" (default: "low")
  - "low": Quick reflection with basic analysis
  - "mid": Moderate depth analysis
  - "high": Comprehensive analysis with deeper exploration
- **--context** (optional): Additional context to inform the reflection
- **--max-tokens** (optional): Maximum tokens for the response (default: 4096)

### Example Usage

Basic reflection:

```bash
/hindsight-cc:reflect "Should I use REST or GraphQL for this API?"
```

With budget and context:

```bash
/hindsight-cc:reflect "Authentication strategy decision" --budget high --context "Building microservices architecture with multiple client types"
```

For architectural decisions:

```bash
/hindsight-cc:reflect "Database choice for this use case" --budget mid --context "Need to handle 10K writes/sec with strong consistency"
```

## How to Handle Output

The script returns a reflection response based on past context and the query. Use this output to:

1. **Inform your decision-making** - Consider the insights and recommendations provided
2. **Present key findings to the user** - Summarize relevant trade-offs, considerations, and recommendations
3. **Validate your approach** - Use the reflection to confirm or adjust your implementation strategy
4. **Document reasoning** - Reference the reflection when explaining your chosen approach

If the reflection suggests a different approach than you initially considered, explain the trade-offs to the user and recommend the best path forward based on the analysis.
