# Comprehensive Agent Skills Documentation

This document contains ALL the information needed to create effective Agent Skills for Claude Code, Claude.ai, and the Claude Developer Platform.

> Agent Skills are now a formal open standard at **[agentskills.io](https://agentskills.io)**, adopted by 35+ tools (Cursor, Gemini CLI, GitHub Copilot, VS Code, OpenAI Codex, Goose, Kiro, OpenHands, Letta, Amp, Junie, Databricks Genie, Snowflake Cortex Code, Spring AI, Laravel Boost, Factory, OpenCode, Roo Code, and more). **Claude Code implements a superset** of the standard — see [Agent Skills Open Standard](#agent-skills-open-standard-agentskillsio) for the spec and the Claude-Code-only extensions.

## Table of Contents

1. [Introduction](#introduction)
2. [What are Agent Skills?](#what-are-agent-skills)
3. [How Skills Work](#how-skills-work)
4. [Core Principles for Creating Skills](#core-principles-for-creating-skills)
5. [Skill Structure](#skill-structure)
6. [Invocation Control](#invocation-control)
7. [String Substitutions](#string-substitutions)
8. [Dynamic Context Injection](#dynamic-context-injection)
9. [Running Skills in a Subagent](#running-skills-in-a-subagent)
9a. [Skill Content Lifecycle (Claude Code)](#skill-content-lifecycle-claude-code)
9b. [Reference vs Task Content](#reference-vs-task-content)
10. [Writing Effective Descriptions](#writing-effective-descriptions)
11. [Progressive Disclosure Patterns](#progressive-disclosure-patterns)
12. [Workflows and Feedback Loops](#workflows-and-feedback-loops)
13. [Content Guidelines](#content-guidelines)
14. [Common Patterns](#common-patterns)
15. [Anti-Patterns to Avoid](#anti-patterns-to-avoid)
16. [Advanced: Skills with Executable Code](#advanced-skills-with-executable-code)
17. [Using Skills Across Platforms](#using-skills-across-platforms)
18. [Bundled Skills (Claude Code)](#bundled-skills-claude-code)
19. [Skill Permission Control (Claude Code)](#skill-permission-control-claude-code)
20. [Evaluation and Iteration](#evaluation-and-iteration)
21. [Security Considerations](#security-considerations)
22. [Troubleshooting](#troubleshooting)
23. [Complete Examples](#complete-examples)
24. [Agent Skills Open Standard (agentskills.io)](#agent-skills-open-standard-agentskillsio)
25. [Checklist for Effective Skills](#checklist-for-effective-skills)

---

## Introduction

Agent Skills are organized folders of instructions, scripts, and resources that agents can discover and load dynamically to perform better at specific tasks. Skills provide Claude with domain-specific expertise, workflows, context, and best practices that transform general-purpose agents into specialists.

### Why Use Skills

**Skills are reusable, filesystem-based resources** that provide:

- **Specialize Claude**: Tailor capabilities for domain-specific tasks
- **Reduce repetition**: Create once, use automatically across multiple conversations
- **Compose capabilities**: Combine Skills to build complex workflows
- **Efficient context usage**: Only loads what's needed, when it's needed
- **Portable**: Same format works across Claude.ai, Claude API, Claude Code, and Claude Agent SDK

### Key Characteristics

**Skills are:**

- **Dual-invocable**: Both model-invoked (Claude autonomously decides when to use them) AND user-invocable (type `/skill-name` to invoke directly). Frontmatter fields let you restrict to one or the other
- **Composable**: Skills stack together. Claude automatically identifies which skills are needed and coordinates their use
- **Portable**: Skills use the same format everywhere. Build once, use across Claude apps, Claude Code, and API
- **Efficient**: Progressive disclosure - only loads what's needed, when it's needed
- **Powerful**: Skills can include executable code for tasks where traditional programming is more reliable than token generation

> **Note**: Custom commands (`.claude/commands/`) have been merged into skills. A file at `.claude/commands/review.md` and a skill at `.claude/skills/review/SKILL.md` both create `/review` and work the same way. Your existing `.claude/commands/` files keep working. Skills add optional features: a directory for supporting files, frontmatter to control invocation, and the ability for Claude to load them automatically when relevant. If a skill and a command share the same name, the skill takes precedence.

---

## What are Agent Skills?

Agent Skills package expertise into discoverable capabilities. Each Skill consists of:

1. **SKILL.md file** (required) with YAML frontmatter containing name and description
2. **Instructions** in the body of SKILL.md that Claude reads when relevant
3. **Optional supporting files** like additional markdown documentation, scripts, templates, and resources

Skills leverage Claude's VM environment to provide capabilities beyond what's possible with prompts alone. Claude operates in a virtual machine with filesystem access, allowing Skills to exist as directories containing instructions, executable code, and reference materials.

### Skills vs Prompts

| Feature | Skills | Prompts |
|---------|--------|---------|
| **Scope** | Reusable across conversations | Single conversation |
| **Invocation** | Both user (`/name`) and Claude (automatic) | Manual only |
| **Loading** | On-demand, progressive | All upfront |
| **Discovery** | Automatic based on metadata | Manual invocation |
| **Context** | Minimal until triggered | Consumes context immediately |
| **Updates** | Edit files, changes persist | Re-type each time |
| **Code** | Can bundle executable scripts | Only generated on-the-fly |
| **Arguments** | Support `$ARGUMENTS` substitution | N/A |

---

## How Skills Work

### Three Levels of Loading (Progressive Disclosure)

Skills leverage **progressive disclosure**: Claude loads information in stages as needed, rather than consuming context upfront.

#### Level 1: Metadata (always loaded)

**Content type: Instructions**. The Skill's YAML frontmatter provides discovery information:

```yaml
---
name: pdf-processing
description: Extract text and tables from PDF files, fill forms, merge documents. Use when working with PDF files or when the user mentions PDFs, forms, or document extraction.
---
```

Claude loads this metadata at startup and includes it in the system prompt. This lightweight approach means you can install many Skills without context penalty; Claude only knows each Skill exists and when to use it.

**Token cost**: ~100 tokens per Skill

#### Level 2: Instructions (loaded when triggered)

**Content type: Instructions**. The main body of SKILL.md contains procedural knowledge: workflows, best practices, and guidance.

When you request something that matches a Skill's description, Claude reads SKILL.md from the filesystem via bash. Only then does this content enter the context window.

**Token cost**: Under 5k tokens (keep SKILL.md body under 500 lines)

#### Level 3: Resources and Code (loaded as needed)

**Content types: Instructions, code, and resources**. Skills can bundle additional materials:

```
pdf-skill/
├── SKILL.md (main instructions)
├── FORMS.md (form-filling guide)
├── REFERENCE.md (detailed API reference)
└── scripts/
    └── fill_form.py (utility script)
```

- **Instructions**: Additional markdown files containing specialized guidance and workflows
- **Code**: Executable scripts that Claude runs via bash; scripts provide deterministic operations without consuming context
- **Resources**: Reference materials like database schemas, API documentation, templates, or examples

Claude accesses these files only when referenced.

**Token cost**: Effectively unlimited. Files executed via bash don't load into context; only output consumes tokens.

| Level | When Loaded | Token Cost | Content |
|-------|-------------|------------|---------|
| **Level 1: Metadata** | Always (at startup) | ~100 tokens per Skill | `name` and `description` from YAML frontmatter |
| **Level 2: Instructions** | When Skill is triggered | Under 5k tokens | SKILL.md body with instructions and guidance |
| **Level 3+: Resources** | As needed | Effectively unlimited | Bundled files executed via bash without loading contents into context |

### The Skills Architecture

Skills run in a code execution environment where Claude has filesystem access, bash commands, and code execution capabilities.

**How Claude accesses Skill content:**

1. **Metadata pre-loaded**: At startup, name and description from all Skills' YAML frontmatter are loaded into the system prompt
2. **Files read on-demand**: Claude uses bash to access SKILL.md and other files from the filesystem when needed
3. **Scripts executed efficiently**: Utility scripts can be executed via bash without loading their full contents into context. Only the script's output consumes tokens
4. **No context penalty for large files**: Reference files, data, or documentation don't consume context tokens until actually read

**What this architecture enables:**

- **On-demand file access**: Claude reads only the files needed for each specific task
- **Efficient script execution**: When Claude runs `validate_form.py`, the script's code never loads into the context window. Only the script's output consumes tokens
- **No practical limit on bundled content**: Because files don't consume context until accessed, Skills can include comprehensive documentation, large datasets, extensive examples, or any reference materials

### Example: Loading a PDF Processing Skill

Here's how Claude loads and uses a PDF processing skill:

1. **Startup**: System prompt includes: `PDF Processing - Extract text and tables from PDF files, fill forms, merge documents`
2. **User request**: "Extract the text from this PDF and summarize it"
3. **Claude invokes**: `bash: read pdf-skill/SKILL.md` → Instructions loaded into context
4. **Claude determines**: Form filling is not needed, so FORMS.md is not read
5. **Claude executes**: Uses instructions from SKILL.md to complete the task

Only relevant content occupies the context window at any given time.

---

## Core Principles for Creating Skills

### 1. Concise is Key

The context window is a public good. Your Skill shares it with everything else Claude needs to know.

**Default assumption**: Claude is already very smart. Only add context Claude doesn't already have.

Challenge each piece of information:
- "Does Claude really need this explanation?"
- "Can I assume Claude knows this?"
- "Does this paragraph justify its token cost?"

**Good example: Concise** (approximately 50 tokens):

````markdown
## Extract PDF text

Use pdfplumber for text extraction:

```python
import pdfplumber

with pdfplumber.open("file.pdf") as pdf:
    text = pdf.pages[0].extract_text()
```
````

**Bad example: Too verbose** (approximately 150 tokens):

```markdown
## Extract PDF text

PDF (Portable Document Format) files are a common file format that contains
text, images, and other content. To extract text from a PDF, you'll need to
use a library. There are many libraries available for PDF processing, but we
recommend pdfplumber because it's easy to use and handles most cases well.
First, you'll need to install it using pip. Then you can use the code below...
```

### 2. Set Appropriate Degrees of Freedom

Match the level of specificity to the task's fragility and variability.

**High freedom** (text-based instructions):
- Multiple approaches are valid
- Decisions depend on context
- Heuristics guide the approach

**Medium freedom** (pseudocode or scripts with parameters):
- A preferred pattern exists
- Some variation is acceptable
- Configuration affects behavior

**Low freedom** (specific scripts, few or no parameters):
- Operations are fragile and error-prone
- Consistency is critical
- A specific sequence must be followed

**Analogy**: Think of Claude as a robot exploring a path:
- **Narrow bridge with cliffs**: Only one safe way forward. Provide specific guardrails (low freedom)
- **Open field**: Many paths lead to success. Give general direction and trust Claude (high freedom)

### 3. Test with All Models You Plan to Use

Skills act as additions to models, so effectiveness depends on the underlying model. Test with:

- **Claude Haiku** (fast, economical): Does the Skill provide enough guidance?
- **Claude Sonnet** (balanced): Is the Skill clear and efficient?
- **Claude Opus** (powerful reasoning): Does the Skill avoid over-explaining?

### 4. Build Evaluations First

**Create evaluations BEFORE writing extensive documentation.** This ensures your Skill solves real problems.

**Evaluation-driven development:**

1. **Identify gaps**: Run Claude on representative tasks without a Skill. Document specific failures or missing context
2. **Create evaluations**: Build three scenarios that test these gaps
3. **Establish baseline**: Measure Claude's performance without the Skill
4. **Write minimal instructions**: Create just enough content to address the gaps and pass evaluations
5. **Iterate**: Execute evaluations, compare against baseline, and refine

---

## Skill Structure

### Basic Directory Structure

```
my-skill/
├── SKILL.md              (required)
├── reference.md          (optional documentation)
├── examples.md           (optional examples)
├── scripts/
│   └── helper.py         (optional utility)
└── templates/
    └── template.txt      (optional template)
```

### SKILL.md Format

Every Skill requires a `SKILL.md` file with YAML frontmatter:

```yaml
---
name: your-skill-name
description: Brief description of what this Skill does and when to use it
---

# Your Skill Name

## Instructions
[Clear, step-by-step guidance for Claude to follow]

## Examples
[Concrete examples of using this Skill]
```

### YAML Frontmatter Reference

All fields are optional. Only `description` is recommended so Claude knows when to use the skill.

| Field | Required | Description |
|-------|----------|-------------|
| `name` | No | Display name for the skill. If omitted, uses the directory name. 1–64 chars, lowercase `a-z`, digits, hyphens only. No leading/trailing hyphen, no consecutive `--`. Must match the parent directory name. |
| `description` | Recommended | What the skill does and when to use it. Claude uses this to decide when to apply the skill. If omitted, uses the first paragraph. **Claude Code**: `description + when_to_use` combined is capped at **1,536 chars** (tunable via `maxSkillDescriptionChars`). **agentskills.io standard**: `description` alone capped at **1,024 chars**. Front-load the key use case. |
| `when_to_use` | No | *(Claude Code)* Additional trigger phrases / example requests, appended to `description` in the skill listing. Counts toward the 1,536-char cap. |
| `argument-hint` | No | Hint shown during autocomplete to indicate expected arguments. Example: `[issue-number]` or `[filename] [format]`. |
| `arguments` | No | *(Claude Code)* Named positional arguments for `$name` substitution. Space-separated string or YAML list; names map to positions in order. |
| `disable-model-invocation` | No | Set to `true` to prevent Claude from automatically loading this skill. Use for workflows you want to trigger manually with `/name`. Also prevents preloading into subagents. Default: `false`. |
| `user-invocable` | No | Set to `false` to hide from the `/` menu. Use for background knowledge users shouldn't invoke directly. Default: `true`. |
| `allowed-tools` | No | Tools Claude can use without per-use approval when this skill is active. Space-separated string or YAML list. For project skills, takes effect only after workspace trust is accepted. |
| `model` | No | *(Claude Code)* Model to use when this skill is active. Per-turn override, not persisted. Accepts `/model` values or `inherit` to keep the active model. |
| `effort` | No | *(Claude Code)* Effort level: `low`, `medium`, `high`, `xhigh`, `max` (availability depends on model). Overrides session effort while skill is active. |
| `context` | No | *(Claude Code)* Set to `fork` to run in a forked subagent context. See [Running Skills in a Subagent](#running-skills-in-a-subagent). |
| `agent` | No | *(Claude Code)* Which subagent type to use when `context: fork` is set. Built-in (`Explore`, `Plan`, `general-purpose`) or custom from `.claude/agents/`. |
| `hooks` | No | *(Claude Code)* Hooks scoped to this skill's lifecycle. See Claude Code hooks documentation. |
| `paths` | No | *(Claude Code)* Glob patterns that limit auto-activation. Comma-separated string or YAML list. When set, Claude auto-loads the skill only when working with matching files. Same format as path-specific rules. |
| `shell` | No | *(Claude Code)* Shell for `` !`cmd` `` and ` ```! ` blocks: `bash` (default) or `powershell`. PowerShell requires `CLAUDE_CODE_USE_POWERSHELL_TOOL=1`. |
| `license` | No | *(agentskills.io standard)* License name or reference to a bundled license file. |
| `compatibility` | No | *(agentskills.io standard)* Environment requirements (intended product, system packages, network access). Max 500 chars. |
| `metadata` | No | *(agentskills.io standard)* Arbitrary string→string map for additional metadata not in the spec. |

**Full example with all optional fields:**

```yaml
---
name: deploy
description: Deploy the application to production
argument-hint: [environment]
disable-model-invocation: true
allowed-tools: Bash(npm *), Bash(git *)
context: fork
agent: general-purpose
---

Deploy $ARGUMENTS to production:
1. Run the test suite
2. Build the application
3. Push to the deployment target
```

**Field validation for `name`:**
- 1–64 characters
- Lowercase `a-z`, digits, and hyphens only
- No leading or trailing hyphen
- No consecutive hyphens (`--`)
- Must match the parent directory name
- Cannot contain XML tags

**Field validation for `description`:**
- agentskills.io standard: max 1,024 characters
- Claude Code: `description + when_to_use` combined max 1,536 chars (tunable via `maxSkillDescriptionChars`)
- Cannot contain XML tags
- Should include both what the Skill does AND when Claude should use it
- Front-load the key use case — text is truncated to fit the listing budget

### Naming Conventions

Use consistent naming patterns. Recommended: **gerund form** (verb + -ing).

**Good naming examples (gerund form)**:
- `processing-pdfs`
- `analyzing-spreadsheets`
- `managing-databases`
- `testing-code`
- `writing-documentation`

**Acceptable alternatives**:
- Noun phrases: `pdf-processing`, `spreadsheet-analysis`
- Action-oriented: `process-pdfs`, `analyze-spreadsheets`

**Avoid**:
- Vague names: `helper`, `utils`, `tools`
- Overly generic: `documents`, `data`, `files`
- Reserved words: `anthropic-helper`, `claude-tools`
- Inconsistent patterns within your skill collection

---

## Invocation Control

By default, both you and Claude can invoke any skill. You can type `/skill-name` to invoke it directly, and Claude can load it automatically when relevant to your conversation. Two frontmatter fields let you restrict this:

### Three Invocation Modes

**Default (both user and Claude can invoke)**:
Best for general-purpose skills like code explanations, analysis tools, or reference knowledge. Both `/skill-name` and automatic invocation work.

**`disable-model-invocation: true` (only user can invoke)**:
Use for workflows with side effects or that you want to control timing: deploy, commit, send-slack-message, database migrations. You don't want Claude deciding to deploy because your code looks ready.

```yaml
---
name: deploy
description: Deploy the application to production
disable-model-invocation: true
---
```

**`user-invocable: false` (only Claude can invoke)**:
Use for background knowledge that isn't actionable as a command. A `legacy-system-context` skill explains how an old system works. Claude should know this when relevant, but `/legacy-system-context` isn't a meaningful action for users to take.

```yaml
---
name: legacy-system-context
description: Context about the legacy billing system architecture. Use when working with billing code or migrating from the old system.
user-invocable: false
---
```

### Invocation Matrix

| Frontmatter | User can invoke | Claude can invoke | When loaded into context |
|-------------|-----------------|-------------------|--------------------------|
| (default) | Yes | Yes | Description always in context, full skill loads when invoked |
| `disable-model-invocation: true` | Yes | No | Description not in context, full skill loads when user invokes |
| `user-invocable: false` | No | Yes | Description always in context, full skill loads when invoked |

> **Note**: In a regular session, skill descriptions are loaded into context so Claude knows what's available, but full skill content only loads when invoked.

---

## String Substitutions

Skills support string substitution for dynamic values in the skill content. Arguments are passed when invoking a skill (e.g., `/fix-issue 123`).

### Available Variables

| Variable | Description |
|----------|-------------|
| `$ARGUMENTS` | All arguments passed when invoking the skill. If `$ARGUMENTS` is not present in the content, arguments are appended as `ARGUMENTS: <value>`. |
| `$ARGUMENTS[N]` | Access a specific argument by 0-based index, such as `$ARGUMENTS[0]` for the first argument. |
| `$N` | Shorthand for `$ARGUMENTS[N]`, such as `$0` for the first argument or `$1` for the second. |
| `$name` | Named positional argument declared in the `arguments` frontmatter. With `arguments: [issue, branch]`, `$issue` = first arg, `$branch` = second. |
| `${CLAUDE_SESSION_ID}` | The current session ID. Useful for logging, creating session-specific files, or correlating skill output with sessions. |
| `${CLAUDE_EFFORT}` | The current effort level (`low`, `medium`, `high`, `xhigh`, `max`). Use to adapt skill instructions to the active effort setting. |
| `${CLAUDE_SKILL_DIR}` | Directory containing the skill's `SKILL.md`. For plugin skills, the skill's subdirectory within the plugin (not the plugin root). **Use this in bash injection commands and script paths so they resolve regardless of cwd.** |

Indexed arguments use shell-style quoting: `/my-skill "hello world" second` → `$0` = `hello world`, `$1` = `second`. `$ARGUMENTS` always expands to the full raw argument string.

### Example: Using `${CLAUDE_SKILL_DIR}` for bundled scripts

```yaml
---
name: codebase-visualizer
description: Generate an interactive HTML tree of the codebase
allowed-tools: Bash(python3 *)
---

Run: `python3 ${CLAUDE_SKILL_DIR}/scripts/visualize.py .`
```

This resolves correctly whether the skill lives at the personal, project, or plugin level.

### Example: Fix a GitHub Issue

```yaml
---
name: fix-issue
description: Fix a GitHub issue
disable-model-invocation: true
---

Fix GitHub issue $ARGUMENTS following our coding standards.

1. Read the issue description
2. Understand the requirements
3. Implement the fix
4. Write tests
5. Create a commit
```

When you run `/fix-issue 123`, Claude receives "Fix GitHub issue 123 following our coding standards..."

### Example: Positional Arguments

```yaml
---
name: migrate-component
description: Migrate a component from one framework to another
---

Migrate the $ARGUMENTS[0] component from $ARGUMENTS[1] to $ARGUMENTS[2].
Preserve all existing behavior and tests.
```

Running `/migrate-component SearchBar React Vue` replaces `$ARGUMENTS[0]` with `SearchBar`, `$ARGUMENTS[1]` with `React`, and `$ARGUMENTS[2]` with `Vue`.

The same skill using the `$N` shorthand:

```yaml
---
name: migrate-component
description: Migrate a component from one framework to another
---

Migrate the $0 component from $1 to $2.
Preserve all existing behavior and tests.
```

### Example: Session Logging

```yaml
---
name: session-logger
description: Log activity for this session
---

Log the following to logs/${CLAUDE_SESSION_ID}.log:

$ARGUMENTS
```

> **Note**: If you invoke a skill with arguments but the skill doesn't include `$ARGUMENTS`, Claude Code appends `ARGUMENTS: <your input>` to the end of the skill content so Claude still sees what you typed.

---

## Dynamic Context Injection

The `` !`command` `` syntax runs shell commands **before** the skill content is sent to Claude. The command output replaces the placeholder, so Claude receives actual data, not the command itself.

This is **preprocessing**, not something Claude executes. Claude only sees the final result.

### Example: PR Summary Skill

This skill summarizes a pull request by fetching live PR data with the GitHub CLI:

```yaml
---
name: pr-summary
description: Summarize changes in a pull request
context: fork
agent: Explore
allowed-tools: Bash(gh *)
---

## Pull request context
- PR diff: !`gh pr diff`
- PR comments: !`gh pr view --comments`
- Changed files: !`gh pr diff --name-only`

## Your task
Summarize this pull request. Include:
1. What changed and why
2. Key files affected
3. Potential risks or concerns
```

When this skill runs:

1. Each `` !`command` `` executes immediately (before Claude sees anything)
2. The output replaces the placeholder in the skill content
3. Claude receives the fully-rendered prompt with actual PR data

### Multi-Line Shell Injection

For multi-line commands, use a fenced code block opened with ` ```! ` instead of the inline form:

````markdown
## Environment
```!
node --version
npm --version
git status --short
```
````

### Disabling Shell Injection

Set `"disableSkillShellExecution": true` in settings to block `` !`cmd` `` and ` ```! ` execution from user/project/plugin/`--add-dir` skills. Each command is replaced with `[shell command execution disabled by policy]`. Bundled and managed skills are unaffected. Most useful in managed settings where users cannot override it.

---

## Running Skills in a Subagent

Add `context: fork` to your frontmatter when you want a skill to run in isolation. The skill content becomes the prompt that drives the subagent. The subagent won't have access to your conversation history.

> **Important**: `context: fork` only makes sense for skills with explicit task instructions. If your skill contains guidelines like "use these API conventions" without a task, the subagent receives the guidelines but no actionable prompt, and returns without meaningful output.

### Example: Research Skill

```yaml
---
name: deep-research
description: Research a topic thoroughly
context: fork
agent: Explore
---

Research $ARGUMENTS thoroughly:

1. Find relevant files using Glob and Grep
2. Read and analyze the code
3. Summarize findings with specific file references
```

When this skill runs:

1. A new isolated context is created
2. The subagent receives the skill content as its prompt ("Research $ARGUMENTS thoroughly...")
3. The `agent` field determines the execution environment (model, tools, and permissions)
4. Results are summarized and returned to your main conversation

The `agent` field specifies which subagent configuration to use. Options include built-in agents (`Explore`, `Plan`, `general-purpose`) or any custom subagent from `.claude/agents/`. If omitted, uses `general-purpose`.

### Skills vs Subagents Comparison

Skills with `context: fork` and subagents work together in two directions:

| Approach | System prompt | Task | Also loads |
|----------|---------------|------|------------|
| Skill with `context: fork` | From agent type (`Explore`, `Plan`, etc.) | SKILL.md content | CLAUDE.md |
| Subagent with `skills` field | Subagent's markdown body | Claude's delegation message | Preloaded skills + CLAUDE.md |

With `context: fork`, you write the task in your skill and pick an agent type to execute it. For the inverse (defining a custom subagent that uses skills as reference material), see the Claude Code subagents documentation.

### When to Use `context: fork`

- **Isolation needed**: The skill's work shouldn't pollute your conversation context
- **Explicit task**: The skill defines a complete, self-contained task
- **Parallel execution**: Multiple forked skills can run concurrently
- **Specialized tools**: The agent type provides appropriate tools for the task

---

## Skill Content Lifecycle (Claude Code)

When you or Claude invoke a skill, the rendered `SKILL.md` content enters the conversation **as a single message and stays for the rest of the session**. Claude Code does **not** re-read the skill file on later turns.

**Implication**: Write guidance that should apply throughout a task as **standing instructions**, not one-time steps.

### Auto-Compaction Behavior

When the conversation is summarized to free context, Claude Code re-attaches the **most recent invocation** of each skill after the summary:

- Keeps the **first 5,000 tokens** of each re-attached skill
- Combined re-attachment budget: **25,000 tokens** total
- Filled most-recently-invoked first; older skills may be dropped entirely if you invoked many

### Debugging "Skill Stopped Working"

If a skill seems to stop influencing behavior after the first response:

1. The content is usually **still present** — the model is choosing other tools/approaches
2. **Strengthen the skill's `description`** and instructions so the model keeps preferring it
3. Use **hooks** to enforce behavior deterministically
4. If the skill is large or many others were invoked after it, **re-invoke after compaction** to restore the full content

---

## Reference vs Task Content

Two patterns for SKILL.md content. Choose based on how you want it invoked and where it runs.

### Reference Content (inline, model-invocable)

Knowledge Claude applies alongside your conversation: conventions, patterns, style guides, domain knowledge. Runs inline with conversation context.

```yaml
---
name: api-conventions
description: API design patterns for this codebase
---

When writing API endpoints:
- Use RESTful naming conventions
- Return consistent error formats
- Include request validation
```

### Task Content (action, usually user-only)

Step-by-step instructions for a specific action: deploy, commit, code-generation pipelines. Often paired with `disable-model-invocation: true` and frequently `context: fork`.

```yaml
---
name: deploy
description: Deploy the application to production
context: fork
disable-model-invocation: true
---

Deploy the application:
1. Run the test suite
2. Build the application
3. Push to the deployment target
```

---

## Writing Effective Descriptions

The `description` field enables Skill discovery and should include both what the Skill does and when to use it.

### Critical Rules

**Always write in third person**. The description is injected into the system prompt.

- **Good:** "Processes Excel files and generates reports"
- **Avoid:** "I can help you process Excel files"
- **Avoid:** "You can use this to process Excel files"

**Be specific and include key terms**. Each Skill has exactly one description field. The description is critical for skill selection: Claude uses it to choose the right Skill from potentially 100+ available Skills.

### Effective Examples

**PDF Processing skill:**

```yaml
description: Extract text and tables from PDF files, fill forms, merge documents. Use when working with PDF files or when the user mentions PDFs, forms, or document extraction.
```

**Excel Analysis skill:**

```yaml
description: Analyze Excel spreadsheets, create pivot tables, generate charts. Use when analyzing Excel files, spreadsheets, tabular data, or .xlsx files.
```

**Git Commit Helper skill:**

```yaml
description: Generate descriptive commit messages by analyzing git diffs. Use when the user asks for help writing commit messages or reviewing staged changes.
```

### Bad Examples (Too Vague)

```yaml
description: Helps with documents
```

```yaml
description: Processes data
```

```yaml
description: Does stuff with files
```

---

## Progressive Disclosure Patterns

SKILL.md serves as an overview that points Claude to detailed materials as needed, like a table of contents in an onboarding guide.

### Practical Guidance

- Keep SKILL.md body under 500 lines for optimal performance
- Split content into separate files when approaching this limit
- Use the patterns below to organize instructions, code, and resources effectively

### Pattern 1: High-Level Guide with References

````markdown
---
name: pdf-processing
description: Extracts text and tables from PDF files, fills forms, and merges documents. Use when working with PDF files or when the user mentions PDFs, forms, or document extraction.
---

# PDF Processing

## Quick start

Extract text with pdfplumber:
```python
import pdfplumber
with pdfplumber.open("file.pdf") as pdf:
    text = pdf.pages[0].extract_text()
```

## Advanced features

**Form filling**: See [FORMS.md](FORMS.md) for complete guide
**API reference**: See [REFERENCE.md](REFERENCE.md) for all methods
**Examples**: See [EXAMPLES.md](EXAMPLES.md) for common patterns
````

Claude loads FORMS.md, REFERENCE.md, or EXAMPLES.md only when needed.

### Pattern 2: Domain-Specific Organization

For Skills with multiple domains, organize content by domain to avoid loading irrelevant context.

```
bigquery-skill/
├── SKILL.md (overview and navigation)
└── reference/
    ├── finance.md (revenue, billing metrics)
    ├── sales.md (opportunities, pipeline)
    ├── product.md (API usage, features)
    └── marketing.md (campaigns, attribution)
```

````markdown
# BigQuery Data Analysis

## Available datasets

**Finance**: Revenue, ARR, billing → See [reference/finance.md](reference/finance.md)
**Sales**: Opportunities, pipeline, accounts → See [reference/sales.md](reference/sales.md)
**Product**: API usage, features, adoption → See [reference/product.md](reference/product.md)
**Marketing**: Campaigns, attribution, email → See [reference/marketing.md](reference/marketing.md)

## Quick search

Find specific metrics using grep:

```bash
grep -i "revenue" reference/finance.md
grep -i "pipeline" reference/sales.md
grep -i "api usage" reference/product.md
```
````

### Pattern 3: Conditional Details

Show basic content, link to advanced content:

```markdown
# DOCX Processing

## Creating documents

Use docx-js for new documents. See [DOCX-JS.md](DOCX-JS.md).

## Editing documents

For simple edits, modify the XML directly.

**For tracked changes**: See [REDLINING.md](REDLINING.md)
**For OOXML details**: See [OOXML.md](OOXML.md)
```

Claude reads REDLINING.md or OOXML.md only when the user needs those features.

### Avoid Deeply Nested References

Claude may partially read files when they're referenced from other referenced files.

**Keep references one level deep from SKILL.md**. All reference files should link directly from SKILL.md.

**Bad example: Too deep**:

```markdown
# SKILL.md
See [advanced.md](advanced.md)...

# advanced.md
See [details.md](details.md)...

# details.md
Here's the actual information...
```

**Good example: One level deep**:

```markdown
# SKILL.md

**Basic usage**: [instructions in SKILL.md]
**Advanced features**: See [advanced.md](advanced.md)
**API reference**: See [reference.md](reference.md)
**Examples**: See [examples.md](examples.md)
```

### Structure Longer Reference Files with Table of Contents

For reference files longer than 100 lines, include a table of contents at the top.

**Example**:

```markdown
# API Reference

## Contents
- Authentication and setup
- Core methods (create, read, update, delete)
- Advanced features (batch operations, webhooks)
- Error handling patterns
- Code examples

## Authentication and setup
...

## Core methods
...
```

---

## Workflows and Feedback Loops

### Use Workflows for Complex Tasks

Break complex operations into clear, sequential steps. For particularly complex workflows, provide a checklist that Claude can copy and check off as it progresses.

**Example 1: Research synthesis workflow** (for Skills without code):

````markdown
## Research synthesis workflow

Copy this checklist and track your progress:

```
Research Progress:
- [ ] Step 1: Read all source documents
- [ ] Step 2: Identify key themes
- [ ] Step 3: Cross-reference claims
- [ ] Step 4: Create structured summary
- [ ] Step 5: Verify citations
```

**Step 1: Read all source documents**

Review each document in the `sources/` directory. Note the main arguments and supporting evidence.

**Step 2: Identify key themes**

Look for patterns across sources. What themes appear repeatedly? Where do sources agree or disagree?

**Step 3: Cross-reference claims**

For each major claim, verify it appears in the source material. Note which source supports each point.

**Step 4: Create structured summary**

Organize findings by theme. Include:
- Main claim
- Supporting evidence from sources
- Conflicting viewpoints (if any)

**Step 5: Verify citations**

Check that every claim references the correct source document. If citations are incomplete, return to Step 3.
````

**Example 2: PDF form filling workflow** (for Skills with code):

````markdown
## PDF form filling workflow

Copy this checklist and check off items as you complete them:

```
Task Progress:
- [ ] Step 1: Analyze the form (run analyze_form.py)
- [ ] Step 2: Create field mapping (edit fields.json)
- [ ] Step 3: Validate mapping (run validate_fields.py)
- [ ] Step 4: Fill the form (run fill_form.py)
- [ ] Step 5: Verify output (run verify_output.py)
```

**Step 1: Analyze the form**

Run: `python scripts/analyze_form.py input.pdf`

This extracts form fields and their locations, saving to `fields.json`.

**Step 2: Create field mapping**

Edit `fields.json` to add values for each field.

**Step 3: Validate mapping**

Run: `python scripts/validate_fields.py fields.json`

Fix any validation errors before continuing.

**Step 4: Fill the form**

Run: `python scripts/fill_form.py input.pdf fields.json output.pdf`

**Step 5: Verify output**

Run: `python scripts/verify_output.py output.pdf`

If verification fails, return to Step 2.
````

### Implement Feedback Loops

**Common pattern**: Run validator → fix errors → repeat

This pattern greatly improves output quality.

**Example 1: Style guide compliance** (for Skills without code):

```markdown
## Content review process

1. Draft your content following the guidelines in STYLE_GUIDE.md
2. Review against the checklist:
   - Check terminology consistency
   - Verify examples follow the standard format
   - Confirm all required sections are present
3. If issues found:
   - Note each issue with specific section reference
   - Revise the content
   - Review the checklist again
4. Only proceed when all requirements are met
5. Finalize and save the document
```

**Example 2: Document editing process** (for Skills with code):

```markdown
## Document editing process

1. Make your edits to `word/document.xml`
2. **Validate immediately**: `python ooxml/scripts/validate.py unpacked_dir/`
3. If validation fails:
   - Review the error message carefully
   - Fix the issues in the XML
   - Run validation again
4. **Only proceed when validation passes**
5. Rebuild: `python ooxml/scripts/pack.py unpacked_dir/ output.docx`
6. Test the output document
```

---

## Content Guidelines

### Avoid Time-Sensitive Information

Don't include information that will become outdated.

**Bad example: Time-sensitive** (will become wrong):

```markdown
If you're doing this before August 2025, use the old API.
After August 2025, use the new API.
```

**Good example** (use "old patterns" section):

```markdown
## Current method

Use the v2 API endpoint: `api.example.com/v2/messages`

## Old patterns

<details>
<summary>Legacy v1 API (deprecated 2025-08)</summary>

The v1 API used: `api.example.com/v1/messages`

This endpoint is no longer supported.
</details>
```

### Use Consistent Terminology

Choose one term and use it throughout the Skill:

**Good - Consistent**:
- Always "API endpoint"
- Always "field"
- Always "extract"

**Bad - Inconsistent**:
- Mix "API endpoint", "URL", "API route", "path"
- Mix "field", "box", "element", "control"
- Mix "extract", "pull", "get", "retrieve"

### Use Forward Slashes for Paths

Always use forward slashes in file paths, even on Windows:

- ✓ **Good**: `scripts/helper.py`, `reference/guide.md`
- ✗ **Avoid**: `scripts\helper.py`, `reference\guide.md`

Unix-style paths work across all platforms.

---

## Common Patterns

### Template Pattern

Provide templates for output format. Match the level of strictness to your needs.

**For strict requirements** (like API responses or data formats):

````markdown
## Report structure

ALWAYS use this exact template structure:

```markdown
# [Analysis Title]

## Executive summary
[One-paragraph overview of key findings]

## Key findings
- Finding 1 with supporting data
- Finding 2 with supporting data
- Finding 3 with supporting data

## Recommendations
1. Specific actionable recommendation
2. Specific actionable recommendation
```
````

**For flexible guidance** (when adaptation is useful):

````markdown
## Report structure

Here is a sensible default format, but use your best judgment based on the analysis:

```markdown
# [Analysis Title]

## Executive summary
[Overview]

## Key findings
[Adapt sections based on what you discover]

## Recommendations
[Tailor to the specific context]
```

Adjust sections as needed for the specific analysis type.
````

### Examples Pattern

For Skills where output quality depends on seeing examples, provide input/output pairs:

````markdown
## Commit message format

Generate commit messages following these examples:

**Example 1:**
Input: Added user authentication with JWT tokens
Output:
```
feat(auth): implement JWT-based authentication

Add login endpoint and token validation middleware
```

**Example 2:**
Input: Fixed bug where dates displayed incorrectly in reports
Output:
```
fix(reports): correct date formatting in timezone conversion

Use UTC timestamps consistently across report generation
```

**Example 3:**
Input: Updated dependencies and refactored error handling
Output:
```
chore: update dependencies and refactor error handling

- Upgrade lodash to 4.17.21
- Standardize error response format across endpoints
```

Follow this style: type(scope): brief description, then detailed explanation.
````

### Conditional Workflow Pattern

Guide Claude through decision points:

```markdown
## Document modification workflow

1. Determine the modification type:

   **Creating new content?** → Follow "Creation workflow" below
   **Editing existing content?** → Follow "Editing workflow" below

2. Creation workflow:
   - Use docx-js library
   - Build document from scratch
   - Export to .docx format

3. Editing workflow:
   - Unpack existing document
   - Modify XML directly
   - Validate after each change
   - Repack when complete
```

If workflows become large or complicated with many steps, consider pushing them into separate files.

---

## Anti-Patterns to Avoid

### Don't Offer Too Many Options

Don't present multiple approaches unless necessary:

````markdown
**Bad example: Too many choices** (confusing):
"You can use pypdf, or pdfplumber, or PyMuPDF, or pdf2image, or..."

**Good example: Provide a default** (with escape hatch):
"Use pdfplumber for text extraction:
```python
import pdfplumber
```

For scanned PDFs requiring OCR, use pdf2image with pytesseract instead."
````

### Don't Assume Tools are Installed

Don't assume packages are available:

````markdown
**Bad example: Assumes installation**:
"Use the pdf library to process the file."

**Good example: Explicit about dependencies**:
"Install required package: `pip install pypdf`

Then use it:
```python
from pypdf import PdfReader
reader = PdfReader("file.pdf")
```"
````

### Don't Use Windows-Style Paths

Always use forward slashes:

- ✓ **Good**: `scripts/helper.py`, `reference/guide.md`
- ✗ **Avoid**: `scripts\helper.py`, `reference\guide.md`

---

## Advanced: Skills with Executable Code

### Solve, Don't Punt

When writing scripts for Skills, handle error conditions rather than punting to Claude.

**Good example: Handle errors explicitly**:

```python
def process_file(path):
    """Process a file, creating it if it doesn't exist."""
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        # Create file with default content instead of failing
        print(f"File {path} not found, creating default")
        with open(path, 'w') as f:
            f.write('')
        return ''
    except PermissionError:
        # Provide alternative instead of failing
        print(f"Cannot access {path}, using default")
        return ''
```

**Bad example: Punt to Claude**:

```python
def process_file(path):
    # Just fail and let Claude figure it out
    return open(path).read()
```

### No "Voodoo Constants"

Configuration parameters should be justified and documented.

**Good example: Self-documenting**:

```python
# HTTP requests typically complete within 30 seconds
# Longer timeout accounts for slow connections
REQUEST_TIMEOUT = 30

# Three retries balances reliability vs speed
# Most intermittent failures resolve by the second retry
MAX_RETRIES = 3
```

**Bad example: Magic numbers**:

```python
TIMEOUT = 47  # Why 47?
RETRIES = 5   # Why 5?
```

### Provide Utility Scripts

Even if Claude could write a script, pre-made scripts offer advantages:

**Benefits of utility scripts**:
- More reliable than generated code
- Save tokens (no need to include code in context)
- Save time (no code generation required)
- Ensure consistency across uses

**Make execution intent clear**:
- "Run `analyze_form.py` to extract fields" (execute)
- "See `analyze_form.py` for the extraction algorithm" (read as reference)

**Example**:

````markdown
## Utility scripts

**analyze_form.py**: Extract all form fields from PDF

```bash
python scripts/analyze_form.py input.pdf > fields.json
```

Output format:
```json
{
  "field_name": {"type": "text", "x": 100, "y": 200},
  "signature": {"type": "sig", "x": 150, "y": 500}
}
```

**validate_boxes.py**: Check for overlapping bounding boxes

```bash
python scripts/validate_boxes.py fields.json
# Returns: "OK" or lists conflicts
```

**fill_form.py**: Apply field values to PDF

```bash
python scripts/fill_form.py input.pdf fields.json output.pdf
```
````

### Use Visual Analysis

When inputs can be rendered as images, have Claude analyze them:

````markdown
## Form layout analysis

1. Convert PDF to images:
   ```bash
   python scripts/pdf_to_images.py form.pdf
   ```

2. Analyze each page image to identify form fields
3. Claude can see field locations and types visually
````

Claude's vision capabilities help understand layouts and structures.

### Create Verifiable Intermediate Outputs

When Claude performs complex, open-ended tasks, use the "plan-validate-execute" pattern.

**Example**: Asking Claude to update 50 form fields in a PDF based on a spreadsheet.

**Solution**: Use the workflow pattern, but add an intermediate `changes.json` file that gets validated before applying changes. The workflow becomes: analyze → **create plan file** → **validate plan** → execute → verify.

**Why this pattern works:**
- **Catches errors early**: Validation finds problems before changes are applied
- **Machine-verifiable**: Scripts provide objective verification
- **Reversible planning**: Claude can iterate on the plan without touching originals
- **Clear debugging**: Error messages point to specific problems

**When to use**: Batch operations, destructive changes, complex validation rules, high-stakes operations.

**Implementation tip**: Make validation scripts verbose with specific error messages like "Field 'signature_date' not found. Available fields: customer_name, order_total, signature_date_signed"

### Package Dependencies

Skills run in the code execution environment with platform-specific limitations:

- **claude.ai**: Can install packages from npm and PyPI and pull from GitHub repositories
- **Anthropic API**: Has no network access and no runtime package installation

List required packages in your SKILL.md and verify they're available in the code execution tool documentation.

### MCP Tool References

If your Skill uses MCP (Model Context Protocol) tools, always use fully qualified tool names.

**Format**: `ServerName:tool_name`

**Example**:

```markdown
Use the BigQuery:bigquery_schema tool to retrieve table schemas.
Use the GitHub:create_issue tool to create issues.
```

Where:
- `BigQuery` and `GitHub` are MCP server names
- `bigquery_schema` and `create_issue` are the tool names within those servers

### Extended Thinking in Skills

To enable extended thinking (thinking mode) in a skill, include the word "ultrathink" anywhere in your skill content. This activates Claude's extended thinking capabilities for more complex reasoning tasks.

---

## Using Skills Across Platforms

### Where Skills Work

Skills are available across Claude's agent products:

- **Claude API**: Pre-built Skills (pptx, xlsx, docx, pdf) and custom Skills via `/v1/skills` endpoints
- **Claude.ai**: Pre-built Skills (automatic) and custom Skills (upload via Settings)
- **Claude Code**: Custom Skills only (filesystem-based)
- **Claude Agent SDK**: Custom Skills via filesystem configuration

### Claude API

The Claude API supports both pre-built Agent Skills and custom Skills.

**Prerequisites**: Three beta headers required:
- `code-execution-2025-08-25` - Skills run in the code execution container
- `skills-2025-10-02` - Enables Skills functionality
- `files-api-2025-04-14` - Required for uploading/downloading files to/from the container

**Quick example** (Python):

```python
import anthropic

client = anthropic.Anthropic()

# Create a message with the PowerPoint Skill
response = client.beta.messages.create(
    model="claude-sonnet-4-5-20250929",
    max_tokens=4096,
    betas=["code-execution-2025-08-25", "skills-2025-10-02"],
    container={
        "skills": [
            {
                "type": "anthropic",
                "skill_id": "pptx",
                "version": "latest"
            }
        ]
    },
    messages=[{
        "role": "user",
        "content": "Create a presentation about renewable energy with 5 slides"
    }],
    tools=[{
        "type": "code_execution_20250825",
        "name": "code_execution"
    }]
)
```

**Pre-built Skills available**:
- **PowerPoint (pptx)**: Create presentations, edit slides, analyze content
- **Excel (xlsx)**: Create spreadsheets, analyze data, generate reports with charts
- **Word (docx)**: Create documents, edit content, format text
- **PDF (pdf)**: Generate formatted PDF documents and reports

**Custom Skills**: Upload via `/v1/skills` endpoints. Shared organization-wide.

### Claude.ai

**Pre-built Agent Skills**: Working behind the scenes when you create documents. No setup required.

**Custom Skills**: Upload as zip files through Settings > Features. Available on Pro, Max, Team, and Enterprise plans with code execution enabled.

**Note**: Custom Skills are individual to each user; not shared organization-wide.

### Claude Code

**Custom Skills only**. Create Skills as directories with SKILL.md files. Claude discovers and uses them automatically. Users can also invoke skills directly via `/skill-name`.

**Skill Locations and Priority**:

Where you store a skill determines who can use it. When skills share the same name across levels, higher-priority locations win:

| Location | Path | Applies to | Priority |
|----------|------|------------|----------|
| Enterprise | Via managed settings | All users in your organization | Highest |
| Personal | `~/.claude/skills/<skill-name>/SKILL.md` | All your projects | High |
| Project | `.claude/skills/<skill-name>/SKILL.md` | This project only | Normal |
| Plugin | `<plugin>/skills/<skill-name>/SKILL.md` | Where plugin is enabled | Namespaced |

Plugin skills use a `plugin-name:skill-name` namespace, so they cannot conflict with other levels.

#### Enterprise Skills

Deployed organization-wide through managed settings. Highest priority. See Claude Code managed settings documentation.

#### Personal Skills

**Location**: `~/.claude/skills/`

```bash
mkdir -p ~/.claude/skills/my-skill-name
```

Use for:
- Individual workflows and preferences
- Experimental Skills you're developing
- Personal productivity tools

#### Project Skills

**Location**: `.claude/skills/` (within your project)

```bash
mkdir -p .claude/skills/my-skill-name
```

Use for:
- Team workflows and conventions
- Project-specific expertise
- Shared utilities and scripts

Project Skills are checked into git and automatically available to team members.

#### Plugin Skills

Skills can also come from Claude Code plugins. Plugins may bundle Skills that are automatically available when the plugin is installed. Plugin skills are namespaced as `plugin-name:skill-name`.

#### Live Change Detection

Claude Code watches skill directories for file changes. **Adding, editing, or removing** a skill under `~/.claude/skills/`, the project `.claude/skills/`, or an `--add-dir`'d `.claude/skills/` takes effect **within the current session without restarting**.

Exception: creating a **top-level skills directory** that did not exist when the session started requires restarting Claude Code so the new directory can be watched.

#### Nested Directory Discovery (Monorepo Support)

When you work with files in subdirectories, Claude Code automatically discovers skills from nested `.claude/skills/` directories. For example, editing `packages/frontend/foo.ts` also pulls in skills from `packages/frontend/.claude/skills/`. Supports monorepo setups where packages have their own skills.

#### Skills from Additional Directories (`--add-dir`)

`--add-dir` grants **file access**, not configuration discovery. **Skills are an exception**: `.claude/skills/` within an added directory is loaded automatically and benefits from live change detection.

Other `.claude/` configuration (subagents, commands, output styles) is **not** loaded from `--add-dir` directories. CLAUDE.md files from added directories are also not loaded by default — set `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` to opt in.

### Claude Agent SDK

The Claude Agent SDK supports custom Skills through filesystem-based configuration.

Create Skills as directories with SKILL.md files in `.claude/skills/`. Enable Skills by including `"Skill"` in your `allowed_tools` configuration.

### Cross-Surface Availability

**Custom Skills do not sync across surfaces**. Skills uploaded to one surface are not automatically available on others:

- Skills uploaded to Claude.ai must be separately uploaded to the API
- Skills uploaded via the API are not available on Claude.ai
- Claude Code Skills are filesystem-based and separate from both

### Sharing Scope

- **Claude.ai**: Individual user only; each team member must upload separately
- **Claude API**: Workspace-wide; all workspace members can access uploaded Skills
- **Claude Code**: Personal (`~/.claude/skills/`) or project-based (`.claude/skills/`)

### Runtime Environment Constraints

**Claude.ai**:
- **Varying network access**: Depending on user/admin settings, Skills may have full, partial, or no network access

**Claude API**:
- **No network access**: Skills cannot make external API calls or access the internet
- **No runtime package installation**: Only pre-installed packages are available
- **Pre-configured dependencies only**: Check the code execution tool documentation for available packages

**Claude Code**:
- **Full network access**: Skills have the same network access as any other program on the user's computer
- **Global package installation discouraged**: Skills should only install packages locally

---

## Bundled Skills (Claude Code)

Bundled skills ship with Claude Code and are available in every session. Unlike built-in commands (like `/help`, `/compact`), which execute fixed logic directly, bundled skills are **prompt-based**: they give Claude a detailed playbook and let it orchestrate the work using its tools. This means bundled skills can spawn parallel agents, read files, and adapt to your codebase.

You invoke bundled skills the same way as any other skill: type `/` followed by the skill name.

### `/simplify`

Reviews your recently changed files for code reuse, quality, and efficiency issues, then fixes them. Run it after implementing a feature or bug fix to clean up your work. It spawns three review agents in parallel (code reuse, code quality, efficiency), aggregates their findings, and applies fixes. Pass optional text to focus on specific concerns:

```
/simplify focus on memory efficiency
```

### `/batch <instruction>`

Orchestrates large-scale changes across a codebase in parallel. Provide a description of the change and `/batch` researches the codebase, decomposes the work into 5 to 30 independent units, and presents a plan for your approval. Once approved, it spawns one background agent per unit, each in an isolated git worktree. Each agent implements its unit, runs tests, and opens a pull request. Requires a git repository.

```
/batch migrate src/ from Solid to React
```

### `/debug [description]`

Troubleshoots your current Claude Code session by reading the session debug log. Optionally describe the issue to focus the analysis.

```
/debug why did the last tool call fail?
```

### `/loop <interval> <prompt>`

Run a prompt or slash command on a recurring interval (e.g. `/loop 5m /check-deploys`). Omit the interval to let the model self-pace. Useful for polling, status checks, or repeated tasks.

### `/claude-api`

Build, debug, and optimize Claude API / Anthropic SDK applications. Auto-activates when code imports `anthropic` or `@anthropic-ai/sdk`. Handles caching, thinking, compaction, tool use, batch, files, citations, memory, and model migrations.

### Built-In Commands Also Reachable Via Skill Tool

A few built-in commands are exposed through the Skill tool and respond to `Skill(name)` permission rules: **`/init`**, **`/review`**, **`/security-review`**. Others like `/compact` are not.

> **Note**: Claude Code also includes a bundled developer platform skill that activates automatically when your code imports the Anthropic SDK. You don't need to invoke it manually.

---

## Skill Permission Control (Claude Code)

By default, Claude can invoke any skill that doesn't have `disable-model-invocation: true` set. Skills that define `allowed-tools` grant Claude access to those tools without per-use approval when the skill is active. Your permission settings still govern baseline approval behavior for all other tools.

### Three Ways to Control Skill Access

**1. Disable all skills** by denying the Skill tool in `/permissions`:

```
# Add to deny rules:
Skill
```

**2. Allow or deny specific skills** using permission rules:

```
# Allow only specific skills
Skill(commit)
Skill(review-pr *)

# Deny specific skills
Skill(deploy *)
```

Permission syntax: `Skill(name)` for exact match, `Skill(name *)` for prefix match with any arguments.

**3. Hide individual skills** by adding `disable-model-invocation: true` to their frontmatter. This removes the skill from Claude's context entirely.

> **Note**: The `user-invocable` field only controls menu visibility, not Skill tool access. Use `disable-model-invocation: true` to block programmatic invocation.

### Skill Visibility Overrides (`skillOverrides`)

The `skillOverrides` setting controls skill visibility **from settings instead of the skill's own frontmatter**. Useful for skills you don't want to (or can't) edit — shared repo skills, MCP-server-provided skills. Set interactively via the `/skills` menu (`Space` cycles state, `Enter` saves to `.claude/settings.local.json`).

Four states per skill:

| Value | Listed to Claude | In `/` menu |
|-------|------------------|-------------|
| `"on"` *(default if absent)* | Name and description | Yes |
| `"name-only"` | Name only (description hidden — frees budget) | Yes |
| `"user-invocable-only"` | Hidden | Yes |
| `"off"` | Hidden | Hidden |

```json
{
  "skillOverrides": {
    "legacy-context": "name-only",
    "deploy": "off"
  }
}
```

Plugin skills are not affected by `skillOverrides` — manage those through `/plugin`.

---

## Evaluation and Iteration

### Build Evaluations First

**Create evaluations BEFORE writing extensive documentation.** This ensures your Skill solves real problems.

**Evaluation-driven development:**

1. **Identify gaps**: Run Claude on representative tasks without a Skill. Document specific failures or missing context
2. **Create evaluations**: Build three scenarios that test these gaps
3. **Establish baseline**: Measure Claude's performance without the Skill
4. **Write minimal instructions**: Create just enough content to address the gaps and pass evaluations
5. **Iterate**: Execute evaluations, compare against baseline, and refine

**Evaluation structure**:

```json
{
  "skills": ["pdf-processing"],
  "query": "Extract all text from this PDF file and save it to output.txt",
  "files": ["test-files/document.pdf"],
  "expected_behavior": [
    "Successfully reads the PDF file using an appropriate PDF processing library or command-line tool",
    "Extracts text content from all pages in the document without missing any pages",
    "Saves the extracted text to a file named output.txt in a clear, readable format"
  ]
}
```

### Develop Skills Iteratively with Claude

Work with one instance of Claude ("Claude A") to create a Skill that will be used by other instances ("Claude B").

**Creating a new Skill:**

1. **Complete a task without a Skill**: Work through a problem with Claude A using normal prompting
2. **Identify the reusable pattern**: After completing the task, identify what context you provided that would be useful for similar future tasks
3. **Ask Claude A to create a Skill**: "Create a Skill that captures this BigQuery analysis pattern we just used"
4. **Review for conciseness**: Check that Claude A hasn't added unnecessary explanations
5. **Improve information architecture**: Ask Claude A to organize content more effectively
6. **Test on similar tasks**: Use the Skill with Claude B (a fresh instance with the Skill loaded) on related use cases
7. **Iterate based on observation**: If Claude B struggles, return to Claude A with specifics

**Iterating on existing Skills:**

1. **Use the Skill in real workflows**: Give Claude B (with the Skill loaded) actual tasks, not test scenarios
2. **Observe Claude B's behavior**: Note where it struggles, succeeds, or makes unexpected choices
3. **Return to Claude A for improvements**: Share the current SKILL.md and describe what you observed
4. **Review Claude A's suggestions**: Claude A might suggest reorganizing, using stronger language, or restructuring
5. **Apply and test changes**: Update the Skill with Claude A's refinements, then test again with Claude B
6. **Repeat based on usage**: Continue this observe-refine-test cycle as you encounter new scenarios

**Why this approach works**: Claude A understands agent needs, you provide domain expertise, Claude B reveals gaps through real usage, and iterative refinement improves Skills based on observed behavior.

### Observe How Claude Navigates Skills

As you iterate on Skills, pay attention to how Claude actually uses them:

- **Unexpected exploration paths**: Does Claude read files in an order you didn't anticipate?
- **Missed connections**: Does Claude fail to follow references to important files?
- **Overreliance on certain sections**: If Claude repeatedly reads the same file, consider whether that content should be in the main SKILL.md
- **Ignored content**: If Claude never accesses a bundled file, it might be unnecessary or poorly signaled

---

## Security Considerations

We strongly recommend using Skills only from trusted sources: those you created yourself or obtained from Anthropic.

Skills provide Claude with new capabilities through instructions and code. A malicious Skill can direct Claude to invoke tools or execute code in ways that don't match the Skill's stated purpose.

### Key Security Considerations

**Audit thoroughly**: Review all files bundled in the Skill: SKILL.md, scripts, images, and other resources. Look for unusual patterns like unexpected network calls, file access patterns, or operations that don't match the Skill's stated purpose.

**External sources are risky**: Skills that fetch data from external URLs pose particular risk, as fetched content may contain malicious instructions. Even trustworthy Skills can be compromised if their external dependencies change over time.

**Tool misuse**: Malicious Skills can invoke tools (file operations, bash commands, code execution) in harmful ways.

**Data exposure**: Skills with access to sensitive data could be designed to leak information to external systems.

**Treat like installing software**: Only use Skills from trusted sources. Be especially careful when integrating Skills into production systems with access to sensitive data or critical operations.

**Warning**: If you must use a Skill from an untrusted or unknown source, exercise extreme caution and thoroughly audit it before use. Depending on what access Claude has when executing the Skill, malicious Skills could lead to data exfiltration, unauthorized system access, or other security risks.

---

## Troubleshooting

### Claude Doesn't Use My Skill

**Check 1: Is the description specific enough?**

Include both what the Skill does and when to use it, with key terms users would mention.

**Too generic**:
```yaml
description: Helps with data
```

**Specific**:
```yaml
description: Analyze Excel spreadsheets, generate pivot tables, create charts. Use when working with Excel files, spreadsheets, or .xlsx files.
```

**Check 2: Is the YAML valid?**

```bash
# View frontmatter
cat .claude/skills/my-skill/SKILL.md | head -n 15

# Common issues:
# - Missing opening or closing ---
# - Tabs instead of spaces
# - Unquoted strings with special characters
```

**Check 3: Is the Skill in the correct location?**

```bash
# Personal Skills
ls ~/.claude/skills/*/SKILL.md

# Project Skills
ls .claude/skills/*/SKILL.md
```

### Skill Has Errors

**Check 1: Are dependencies available?**

Claude will automatically install required dependencies (or ask for permission).

**Check 2: Do scripts have execute permissions?**

```bash
chmod +x .claude/skills/my-skill/scripts/*.py
```

**Check 3: Are file paths correct?**

Use forward slashes (Unix style): `scripts/helper.py`
Not Windows style: `scripts\helper.py`

### Skill Descriptions Are Cut Short

Skill names are always included in context, but **descriptions are shortened to fit a character budget** when you have many skills. The budget defaults to **1% of the model's context window**. When it overflows, descriptions for the skills you invoke least are dropped first.

**Diagnose**:

```
/doctor
```

Shows whether the budget is overflowing and which skills are affected.

**Tune the budget**:

- `skillListingBudgetFraction` setting — e.g. `0.02` for 2%
- `SLASH_COMMAND_TOOL_CHAR_BUDGET` env var — fixed char count
- `maxSkillDescriptionChars` setting — per-entry cap (default 1,536)

**Free budget for high-priority skills**:

- Set low-priority entries to `"name-only"` in `skillOverrides` (description hidden, slot freed)
- Front-load the key use case in each `description` (each entry is capped regardless of budget)
- Trim `when_to_use` text at the source

### Multiple Skills Conflict

Be specific in descriptions. Use distinct trigger terms.

**Instead of**:
```yaml
# Skill 1
description: For data analysis

# Skill 2
description: For analyzing data
```

**Use**:
```yaml
# Skill 1
description: Analyze sales data in Excel files and CRM exports. Use for sales reports, pipeline analysis, and revenue tracking.

# Skill 2
description: Analyze log files and system metrics data. Use for performance monitoring, debugging, and system diagnostics.
```

---

## Complete Examples

### Example 1: Simple Skill (Single File)

**Structure**:
```
commit-helper/
└── SKILL.md
```

**SKILL.md**:
```yaml
---
name: generating-commit-messages
description: Generates clear commit messages from git diffs. Use when writing commit messages or reviewing staged changes.
---

# Generating Commit Messages

## Instructions

1. Run `git diff --staged` to see changes
2. I'll suggest a commit message with:
   - Summary under 50 characters
   - Detailed description
   - Affected components

## Best practices

- Use present tense
- Explain what and why, not how
```

### Example 2: Skill with Tool Permissions

**Structure**:
```
code-reviewer/
└── SKILL.md
```

**SKILL.md**:
```yaml
---
name: code-reviewer
description: Review code for best practices and potential issues. Use when reviewing code, checking PRs, or analyzing code quality.
allowed-tools: Read, Grep, Glob
---

# Code Reviewer

## Review checklist

1. Code organization and structure
2. Error handling
3. Performance considerations
4. Security concerns
5. Test coverage

## Instructions

1. Read the target files using Read tool
2. Search for patterns using Grep
3. Find related files using Glob
4. Provide detailed feedback on code quality
```

### Example 3: Multi-File Skill

**Structure**:
```
pdf-processing/
├── SKILL.md
├── FORMS.md
├── REFERENCE.md
└── scripts/
    ├── fill_form.py
    └── validate.py
```

**SKILL.md**:
````yaml
---
name: pdf-processing
description: Extract text, fill forms, merge PDFs. Use when working with PDF files, forms, or document extraction. Requires pypdf and pdfplumber packages.
---

# PDF Processing

## Quick start

Extract text:
```python
import pdfplumber
with pdfplumber.open("doc.pdf") as pdf:
    text = pdf.pages[0].extract_text()
```

For form filling, see [FORMS.md](FORMS.md).
For detailed API reference, see [REFERENCE.md](REFERENCE.md).

## Requirements

Packages must be installed in your environment:
```bash
pip install pypdf pdfplumber
```
````

### Example 4: BigQuery Data Analysis Skill

**Structure**:
```
bigquery-skill/
├── SKILL.md
└── reference/
    ├── finance.md
    ├── sales.md
    ├── product.md
    └── marketing.md
```

**SKILL.md**:
````markdown
---
name: bigquery-data-analysis
description: Query and analyze BigQuery data across finance, sales, product, and marketing datasets. Use when analyzing company metrics, generating reports, or querying BigQuery tables.
---

# BigQuery Data Analysis

## Available datasets

**Finance**: Revenue, ARR, billing → See [reference/finance.md](reference/finance.md)
**Sales**: Opportunities, pipeline, accounts → See [reference/sales.md](reference/sales.md)
**Product**: API usage, features, adoption → See [reference/product.md](reference/product.md)
**Marketing**: Campaigns, attribution, email → See [reference/marketing.md](reference/marketing.md)

## Quick search

Find specific metrics using grep:

```bash
grep -i "revenue" reference/finance.md
grep -i "pipeline" reference/sales.md
grep -i "api usage" reference/product.md
```

## Common queries

When the user asks for revenue, always:
1. Filter by `account_type != 'test'`
2. Use UTC timestamps for date filtering
3. Include both MRR and ARR in the results
````

---

## Checklist for Effective Skills

Before sharing a Skill, verify:

### Core Quality

- [ ] Description is specific and includes key terms
- [ ] Description includes both what the Skill does and when to use it
- [ ] Description front-loads the key use case (1,536-char Claude Code cap; 1,024 standard cap)
- [ ] SKILL.md body is under 500 lines
- [ ] Additional details are in separate files (if needed)
- [ ] No time-sensitive information (or in "old patterns" section)
- [ ] Consistent terminology throughout
- [ ] Examples are concrete, not abstract
- [ ] File references are one level deep
- [ ] Progressive disclosure used appropriately
- [ ] Workflows have clear steps
- [ ] Standing instructions written for skill content lifecycle (persists across turns; survives compaction with caveats)
- [ ] Uses `${CLAUDE_SKILL_DIR}` for any bundled script paths

### Code and Scripts

- [ ] Scripts solve problems rather than punt to Claude
- [ ] Error handling is explicit and helpful
- [ ] No "voodoo constants" (all values justified)
- [ ] Required packages listed in instructions and verified as available
- [ ] Scripts have clear documentation
- [ ] No Windows-style paths (all forward slashes)
- [ ] Validation/verification steps for critical operations
- [ ] Feedback loops included for quality-critical tasks

### Testing

- [ ] At least three evaluations created
- [ ] Tested with Haiku, Sonnet, and Opus (if using multiple models)
- [ ] Tested with real usage scenarios
- [ ] Team feedback incorporated (if applicable)

### Documentation Quality

- [ ] Name follows naming conventions (gerund form recommended)
- [ ] YAML frontmatter is valid and complete
- [ ] Description is written in third person
- [ ] File paths use forward slashes
- [ ] Longer reference files include table of contents
- [ ] MCP tools use fully qualified names (if applicable)

---

## Agent Skills Open Standard (agentskills.io)

Agent Skills is a formal **open standard** for extending AI agent capabilities with portable, version-controlled skill folders. Originally developed by Anthropic, released openly, and adopted by 35+ tools as of 2026: **Cursor, Gemini CLI, GitHub Copilot, VS Code, OpenAI Codex, Goose, Kiro, OpenHands, Letta, Amp, Junie, Databricks Genie Code, Snowflake Cortex Code, Spring AI, Laravel Boost, Factory, OpenCode, Roo Code, TRAE, Mistral Vibe, Workshop, Emdash, Ona, Mux, Autohand Code CLI, Firebender, Piebald, Command Code, fast-agent, nanobot, Google AI Edge Gallery, Qodo, VT Code, pi, Agentman**.

> Spec home: <https://agentskills.io> · Source/discussion: <https://github.com/agentskills/agentskills>

### Standard Frontmatter Fields

Per the spec at <https://agentskills.io/specification>:

| Field | Required | Constraints |
|-------|----------|-------------|
| `name` | **Yes** | 1–64 chars, lowercase `a-z` + digits + hyphens. No leading/trailing hyphen, no `--`. Must match parent directory name. |
| `description` | **Yes** | 1–1024 chars. What it does + when to use it. |
| `license` | No | License name or reference to a bundled license file. |
| `compatibility` | No | Max 500 chars. Intended product, required system packages, network access, etc. |
| `metadata` | No | Arbitrary string→string map for non-spec metadata. |
| `allowed-tools` | No | Space-separated pre-approved tools. **Experimental** — support varies between agents. |

### Claude Code Extensions to the Standard

Claude Code implements a **superset**. Fields beyond the standard:

`when_to_use` · `argument-hint` · `arguments` · `disable-model-invocation` · `user-invocable` · `model` · `effort` · `context` · `agent` · `hooks` · `paths` · `shell`

Plus settings-level controls: `skillOverrides`, `disableSkillShellExecution`, `skillListingBudgetFraction`, `maxSkillDescriptionChars`.

### Standard Directory Layout

```
my-skill/
├── SKILL.md          # Required: metadata + instructions
├── scripts/          # Optional: executable code
├── references/       # Optional: documentation
├── assets/           # Optional: templates, resources
└── ...               # Any additional files
```

> The standard uses `references/` (plural); Claude Code's examples often use flat reference files at the skill root. Both work in Claude Code.

### Validation

Use the reference library to validate against the standard:

```bash
skills-ref validate ./my-skill
```

Checks frontmatter validity and naming conventions. See <https://github.com/agentskills/agentskills/tree/main/skills-ref>.

### Cross-Tool Portability

A skill written to the standard works in any compatible agent. Tool-specific extensions (Claude Code's `context: fork`, `paths`, etc.) are ignored by other agents. Keep portable skills minimal; opt into extensions when you need them.

---

## Resources

### Official Documentation

- [Agent Skills Open Standard](https://agentskills.io) — agentskills.io home
- [Agent Skills Specification](https://agentskills.io/specification) — formal SKILL.md spec
- [Use Skills in Claude Code](https://code.claude.com/docs/en/skills) — canonical Claude Code reference
- [Agent Skills Overview (Claude platform)](https://docs.claude.com/en/docs/agents-and-tools/agent-skills/overview)
- [Agent Skills Quickstart](https://docs.claude.com/en/docs/agents-and-tools/agent-skills/quickstart)
- [Best Practices Guide](https://docs.claude.com/en/docs/agents-and-tools/agent-skills/best-practices)
- [Use Skills with the Claude API](https://docs.claude.com/en/docs/build-with-claude/skills-guide)
- [Agent Skills in the SDK](https://docs.claude.com/en/docs/agent-sdk/skills)

### GitHub Resources

- [agentskills.io Repo & Discussion](https://github.com/agentskills/agentskills)
- [skills-ref Validator](https://github.com/agentskills/agentskills/tree/main/skills-ref)
- [Agent Skills Cookbook](https://github.com/anthropics/claude-cookbooks/tree/main/skills)
- [Example Skills Repository](https://github.com/anthropics/skills)

### Blog Posts

- [Equipping agents for the real world with Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills)

### Help Center (Claude.ai)

- [What are Skills?](https://support.claude.com/en/articles/12512176-what-are-skills)
- [Using Skills in Claude](https://support.claude.com/en/articles/12512180-using-skills-in-claude)
- [How to create custom Skills](https://support.claude.com/en/articles/12512198-creating-custom-skills)
- [Teach Claude your way of working using Skills](https://support.claude.com/en/articles/12580051-teach-claude-your-way-of-working-using-skills)

---

## Quick Reference Commands

```bash
# Create personal skill
mkdir -p ~/.claude/skills/my-skill-name

# Create project skill
mkdir -p .claude/skills/my-skill-name

# List personal skills
ls ~/.claude/skills/

# List project skills
ls .claude/skills/

# View skill content
cat ~/.claude/skills/my-skill/SKILL.md

# View a specific skill's frontmatter
cat .claude/skills/my-skill/SKILL.md | head -n 15

# Check for valid SKILL.md files
ls ~/.claude/skills/*/SKILL.md
ls .claude/skills/*/SKILL.md
```

---

## YAML Frontmatter Template

```yaml
---
name: skill-name                             # Required by standard; matches dir name
description: What this skill does and when to use it (front-load key use case)
when_to_use: Extra trigger phrases           # Claude Code: appended to description
argument-hint: [optional-args-hint]          # Shown during autocomplete
arguments: [issue, branch]                   # Claude Code: named positional args
disable-model-invocation: false              # true = only user can invoke
user-invocable: true                         # false = hidden from / menu
allowed-tools: Read Write Bash               # Pre-approved tools (space-separated)
model: inherit                               # Claude Code: model override or 'inherit'
effort: medium                               # Claude Code: low|medium|high|xhigh|max
context: fork                                # Claude Code: run in subagent
agent: Explore                               # Claude Code: subagent type (with context: fork)
paths: "src/**/*.ts, tests/**/*.ts"          # Claude Code: limit auto-activation
shell: bash                                  # Claude Code: bash (default) or powershell
license: MIT                                 # Standard: license name or file
compatibility: Requires git, jq              # Standard: env requirements (max 500 chars)
metadata:                                    # Standard: arbitrary string→string map
  author: example-org
  version: "1.0"
---
```

---

**Document Created**: November 12, 2025
**Document Updated**: May 11, 2026
**Document Version**: 4.0
**Sources**: agentskills.io home + specification, code.claude.com/docs/en/skills, Official Anthropic documentation (overview.md, quickstart.md, best-practices.md), Engineering blog post, GitHub cookbooks

**v4.0 changes**: agentskills.io open standard now formally documented; new frontmatter fields (`when_to_use`, `arguments`, `effort`, `paths`, `shell`); new substitutions (`$name`, `${CLAUDE_EFFORT}`, `${CLAUDE_SKILL_DIR}`); skill content lifecycle (persistence + auto-compaction handling); `skillOverrides` settings; skill listing budget controls; multi-line shell injection; `disableSkillShellExecution`; Reference vs Task content distinction; expanded bundled skills (`/loop`, `/claude-api`, `/init`/`/review`/`/security-review` via Skill tool); `--add-dir` skills-only exception; name validation corrected (no consecutive hyphens, must match dir name, no reserved-word rule); description cap clarified (1,536 Claude Code combined vs 1,024 standard).
