---
name: documenting-project-context
description: Captures important project information, architectural decisions, conventions, and learnings to CLAUDE.MD for persistence across sessions. Use after completing significant work, discovering project patterns, making architectural decisions, identifying gotchas, or when information would be valuable for future sessions. Trigger when user says "update CLAUDE.MD", "document this", or proactively when important context emerges.
---

# Documenting Project Context

Maintains CLAUDE.MD as persistent memory across Claude sessions by capturing important project information, architectural decisions, and learnings.

**Core principle**: Concise, scannable, focused on what you need to remember while coding—not comprehensive documentation.

## When to Use This Skill

Trigger this skill when:
- Completing significant work (features, bug fixes, refactoring)
- Discovering architectural decisions or patterns
- Identifying project conventions or coding standards
- Finding gotchas, pitfalls, or non-obvious behaviors
- Learning about dependencies, configurations, or setup requirements
- User explicitly requests: "update CLAUDE.MD", "document this", "add to project notes"

**Proactive mode**: Offer to update CLAUDE.MD when you notice important context that should persist.

## What Qualifies as "Important Information"

**DO document**:
- **Critical constraints**: Architecture rules that MUST be followed (e.g., "modules MUST be single files")
- **Gotchas**: Non-obvious behaviors, common pitfalls, "shell vs .env precedence"
- **Architectural decisions with rationale**: Why X was chosen over Y
- **Key patterns**: Important cross-file relationships and data flows
- **Setup essentials**: Critical env vars, AWS config, deployment specifics
- **Common pitfalls**: Top 10 things that trip people up

**DON'T document**:
- Implementation details visible in a single file (use code comments)
- Verbose explanations of how things work (assume Claude is smart)
- Comprehensive API documentation (link to code/docs instead)
- Temporary states, current work, TODOs
- Self-explanatory standard patterns
- Information easily found by reading the code

## Compression Principles

**Assume Claude is smart**: Only add context Claude doesn't already have.

**Challenge each piece**:
- "Does Claude really need this explanation?"
- "Is this easily discoverable through code exploration?"
- "Does this paragraph justify its context window cost?"

**Good (concise, ~40 tokens)**:
```markdown
### API Key Logic
`get_openai_api_key()` in `core/chat_send_message.py`:
- If agent has `openai_api_key_ssm` → Use SSM (even in DEV)
- Otherwise → Fall back to `OPENAI_API_KEY` env var

**Shell gotcha**: Shell-exported `OPENAI_API_KEY` overrides `.env`. Causes "vector store not found" errors.
```

**Bad (verbose, ~120 tokens)**:
```markdown
### API Key Logic
The application needs to retrieve OpenAI API keys to make API calls to OpenAI's services. We have implemented a function called `get_openai_api_key()` which is located in the `core/chat_send_message.py` file. This function checks whether the agent has a specific configuration field called `openai_api_key_ssm` and if it does, the function will use AWS Systems Manager Parameter Store to retrieve the API key. If the agent does not have this configuration, the function will fall back to using the environment variable called `OPENAI_API_KEY`. This allows for flexibility in how API keys are managed...
```

## Structure Guidelines

### Critical Constraints First
Put "must know" information at the very top:
```markdown
## Critical Architectural Constraints

### 1. Modules MUST Be Single Files
**IMPORTANT**: Command handlers in `modules/` MUST be single `.py` files...

### 2. Route Registration Order
Routes register in strict order - conflicts are silently skipped...
```

### Use Scannable Format
- **Bullets > Prose**: Use bullet points, not paragraphs
- **Clear hierarchy**: ## sections, ### subsections, - bullets
- **Quick reference**: Put logs, commands, debugging in dedicated sections
- **Code with context**: Show minimal example with key point

### Consolidate Related Info
Avoid redundant sections:
- ❌ Bad: "Important Files" AND "Critical Files" AND "Key Locations"
- ✅ Good: Single "Critical Files" section grouped by purpose

### Length Targets
- **Quick Start**: ~10 lines
- **Critical Constraints**: ~40 lines
- **Common Pitfalls**: Top 10 issues, 1-2 lines each
- **Total**: Aim for 200-300 lines max (not 1000+)

## Workflow

### 1. Read existing CLAUDE.MD

```bash
cat CLAUDE.MD
```

If CLAUDE.MD doesn't exist, create it with basic structure.

### 2. Identify the appropriate section

**Recommended structure** (in priority order):
1. **Quick Start**: Essential commands to get running
2. **Critical Architectural Constraints**: Rules that MUST be followed
3. **Key Systems**: Brief overview of major components (bullets)
4. **Common Pitfalls**: Top 10 gotchas (numbered list)
5. **Critical Files**: Grouped by purpose (core logic, config, etc.)
6. **AWS/Deployment**: Account, profile, key resources
7. **Debugging Quick Reference**: Log patterns, common commands

### 3. Format information clearly

**Template for constraints/gotchas**:
```markdown
### [Constraint/Pattern Name]
**Rule**: One-line summary
**Reason**: Why this matters
**Gotcha**: What breaks if you ignore this

Example: [minimal code showing the point]
```

**Template for systems**:
```markdown
### [System Name]
- **Purpose**: One-line description
- **Key files**: `path/to/file.py` - what it does
- **Important**: Critical gotcha or constraint
```

### 4. Update CLAUDE.MD

- **Update, don't append**: If information changes, update existing entry
- **Compress while adding**: If section is getting long, compress it
- **Remove redundancy**: Check if similar info exists elsewhere
- **Use Edit tool**: Make precise updates, preserve structure

### 5. Confirm with user

Tell the user:
- What was documented
- Where it was added
- Why it matters

## Examples

**Example 1: Critical Constraint (Good)**

```markdown
## Critical Architectural Constraints

### 1. Modules MUST Be Single Files
Command handlers in `modules/` MUST be single `.py` files with a `handle()` function. The module loader loads Python files directly - do NOT split into subdirectories.

```python
# modules/example.py - CORRECT
def handle(request_data):
    return response_data

# modules/example/ - WRONG, will not load
```
```

**Example 2: System Overview (Good - Concise)**

```markdown
### Database Abstraction
- **Router**: `utils/dynamodb.py` routes all DB access based on `DB_ENGINE`
- **Backends**: SQLite (dev), DynamoDB (prod)
- **Schema**: Agent configs in `assistants-router-auth` table
```

**Example 3: System Overview (Bad - Too Verbose)**

```markdown
### Database Abstraction

The application uses a database abstraction layer to support multiple database backends. This allows developers to use SQLite during local development for convenience, while production uses DynamoDB for scalability and managed infrastructure.

The database routing logic is implemented in the utils/dynamodb.py file, which checks the DB_ENGINE environment variable to determine which backend to use. When DB_ENGINE is set to "sqlite", all database operations are routed to the SQLite implementation in utils/sqlitedb.py. When it's set to "dynamodb", operations are routed to the DynamoDB implementation.

The schema stores agent configurations in a table called assistants-router-auth. This table contains all the metadata about each agent including its title, description, prompt, and configuration settings.
```

**Example 4: Common Pitfall (Good)**

```markdown
## Common Pitfalls

1. **Modules not loading**: Must be single `.py` files in `modules/`, not subdirectories
2. **API key mismatch**: Shell `OPENAI_API_KEY` overrides `.env`, causes "vector store not found"
3. **Auth bypass not working**: Need BOTH `DEV=True` AND `DEV_ENABLE_AUTH=False`
```

**Example 5: Quick Reference (Good)**

```markdown
## Debugging Quick Reference

**Log patterns**:
- `🔍` - OIDC configuration
- `✅` - Success
- `☁️` - SSM operations

**CloudWatch Logs**:
```bash
AWS_PROFILE=entarch aws logs tail /ecs/Assistants --follow
```

**Common Issues**:
- "exec format error": Set `platform=Platform.LINUX_AMD64` (M1 Mac)
- Health check failures: Add `health_check_grace_period=60s`
```

## Proactive Suggestions

Offer to update CLAUDE.MD when you notice:
- "This constraint seems critical. Should I document it at the top of CLAUDE.MD?"
- "We just hit a gotcha with [X]. Want me to add it to Common Pitfalls?"
- "I notice the CLAUDE.md is getting long. Should I compress and reorganize it?"

## Best Practices

1. **Critical constraints first**: Put "must knows" at the very top
2. **Assume Claude is smart**: Skip verbose explanations
3. **Scannable structure**: Bullets, clear hierarchy, not prose
4. **Compress aggressively**: Aim for 200-300 lines total, not 1000+
5. **Focus on gotchas**: What breaks? What's non-obvious?
6. **Remove implementation details**: If it's in the code, don't duplicate
7. **Update, don't append**: Keep it fresh, not historical
8. **Consolidate sections**: Avoid redundant organization

## File Location

CLAUDE.MD is always at the project root. If working in a subdirectory:
```bash
cat ../CLAUDE.MD       # one level deep
cat ../../CLAUDE.MD    # two levels deep
```
