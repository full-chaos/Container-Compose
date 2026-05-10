# Documentation Standards

Guidelines for maintaining and expanding the Container-Compose documentation.

## Organization

Documentation is structured by intent:
- `docs/cli/`: Reference pages for every subcommand.
- `docs/tutorials/`: Step-by-step guides for specific use cases.
- `docs/concepts/`: Deep dives into architecture and behavior.

## Style Rules

- **Terse Imperative Voice**: Use "Run the command" instead of "You should run the command".
- **Code-First**: Lead with examples. Explain the "why" after showing the "how".
- **Terminal Annotations**: Use `title="terminal"` on all shell code blocks.
- **Feature Linking**: Link every mention of a feature to its reference or concept page.
- **No Filler**: Avoid words like "simply", "obviously", or "just".

## Templates

### CLI Subcommand Reference
`docs/cli/<command>.md`

```markdown
---
title: <command>
description: Brief one-sentence summary of what the command does.
---

# <command>

Detailed description of the command's purpose and behavior.

## Synopsis

```bash title="terminal"
container-compose <command> [options] [args]
```

## Options

| Option | Shorthand | Description |
| :--- | :--- | :--- |
| `--flag` | `-f` | Description of the flag. |

## Examples

### Basic Usage
Description of the example.
```bash title="terminal"
container-compose <command>
```

## Anti-Patterns

- **Don't do X**: Explain why X is bad and what to do instead.
```

### Tutorial Page
`docs/tutorials/<topic>.md`

```markdown
---
title: <topic>
description: What the user will build or achieve in this tutorial.
---

# <topic>

Introduction to the tutorial goals.

## Prerequisites

- List of requirements.

## Step 1: <Action>

Description and code.
```bash title="terminal"
# code
```

## Summary

Recap of what was learned.
```

### Concept Page
`docs/concepts/<topic>.md`

```markdown
---
title: <topic>
description: High-level overview of the concept.
---

# <topic>

Deep dive into the technical details.

## Architecture

How it works under the hood.

## Behavior

Expected outcomes and edge cases.
```

## How to add a new doc

1. **Identify the category**: Choose between `cli/`, `tutorials/`, or `concepts/`.
2. **Apply the template**: Copy the relevant skeleton from this page.
3. **Write the content**: Follow the style rules (terse, code-first).
4. **Link from index**: Add your new page to the appropriate section in `docs/index.md`.
