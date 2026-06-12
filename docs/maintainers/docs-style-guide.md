# Documentation Style Guide

This guide keeps BMF docs readable as the project grows.

## Who Should Read This?

BMF maintainers should use it before adding or reviewing docs. Plugin authors
can use it when contributing examples or API notes.

## Page Shape

Use this order for API pages:

1. What the API is for.
2. Compact labels.
3. Who should read it.
4. When to use it.
5. Lua usage.
6. Server-console routes when they exist.
7. Result shape, gates, and capability requirements.
8. Validation links.

Architecture pages should explain ownership, trust boundaries, and message flow.
They should not duplicate parameter reference text.

Validation pages should hold proof history, canary names, and promotion risk.
They should not redefine API contracts.

## Voice

- Prefer short paragraphs and tables over long narrative blocks.
- Explain the current contract first, then caveats.
- Use active wording: "BMF writes..." instead of "It is written by BMF..."
- Link to the owning page instead of re-explaining a concept.
- Keep historical lab notes out of API pages.

## Labels

Use compact labels near the top of important API pages:

```markdown
**Labels:** `experimental`, `unsafe-native`, `L2 Headless`, `L6 required`
```

Label terms are defined in the [Glossary](../reference/glossary.md).

## Warnings

Use admonitions for risk:

```markdown
!!! warning
    Use this for crash risk, unstable identity, unsafe reads, or restart-sensitive
    behavior.

!!! danger
    Use this for broad native/console escape hatches or paths that can crash or
    mutate live state unexpectedly.
```

Avoid burying crash warnings in normal prose.

## Ownership Rules

| Content | Owning page |
| --- | --- |
| Public parameters, return fields, result codes | API reference |
| High-level diagrams and trust boundaries | Architecture patterns |
| Runtime ownership and Omegga/BMF split | Supported runtime matrix |
| Validation history and canary names | API validation evidence |
| Native hook sync and pointer-sensitive details | Native hook notes |
| Terms and labels | Glossary |
| Step-by-step reader paths | Common workflows |

## Link Rules

- Prefer relative Markdown links.
- Link once to the owning page rather than repeating detailed prose.
- Do not link to removed or renamed pages.
- Do not add a docs page without adding it to `mkdocs.yml`.

## Local Checks

Run:

```powershell
python .\scripts\validate-docs-style.py
python -m mkdocs build --strict
```

The style script checks for stale links, missing navigation entries, heading
shape, and trailing whitespace. `mkdocs build --strict` checks nav, rendering,
and Markdown links.
