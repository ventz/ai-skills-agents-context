# AI Skills, Agents & Context

<p><strong>⭐ If AI Skills, Agents &amp; Context is useful to you, please star it: click the ☆ Star button at the top right of the <a href="https://github.com/ventz/ai-skills-agents-context">GitHub repo page</a>.</strong></p>
<a href="https://github.com/ventz/ai-skills-agents-context/stargazers"><img src="https://img.shields.io/github/stars/ventz/ai-skills-agents-context?style=social" alt="GitHub stars"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
<img src="https://img.shields.io/badge/Claude%20Code-agents%20%7C%20skills-d97757.svg" alt="Claude Code: agents and skills">

Battle-tested Claude Code **subagents**, **skills** and long-form **context guides** ("golden docs"): auditors for security, accessibility and code completeness; consult agents that hand questions to OpenAI, Google Gemini and xAI Grok through their CLIs; and reference guides for writing Agent Skills and MCP servers. Everything is plain Markdown you can drop into `~/.claude/`.

## Table of Contents

- [Overview](#overview)
- [Quick Install](#quick-install)
- [What's Inside](#whats-inside)
  - [Auditor Agents](#auditor-agents)
  - [Consult Agents (OpenAI, Google, xAI)](#consult-agents-openai-google-xai)
  - [Skills](#skills)
  - [Context Guides](#context-guides)
  - [Helper Scripts](#helper-scripts)
- [Usage](#usage)
- [Requirements](#requirements)
- [Security Model](#security-model)
- [Repository Layout](#repository-layout)
- [Staying Current](#staying-current)
- [Contributing](#contributing)
- [License](#license)

## Overview

These files are the working set behind a daily Claude Code setup, published after each change. They solve two problems:

- **Reviews that stop halfway.** The auditor agents carry long, numbered checklists (secure-coding patterns, WCAG 2.2 success criteria, completeness checks across 15+ languages and IaC tools), so a review covers the same ground every time and reports findings in a fixed, severity-ranked format.
- **One model's blind spots.** The consult agents let Claude ask another frontier model for a second opinion, live web research or a security audit, while Claude stays the one that writes and commits the code.

Each agent is a single Markdown file with YAML frontmatter (`name`, `description`, `model`, `color`) followed by its system prompt. The `description` decides when Claude Code calls the agent, and each one includes `<example>` blocks of real trigger phrases.

## Quick Install

```bash
git clone https://github.com/ventz/ai-skills-agents-context
cd ai-skills-agents-context
mkdir -p ~/.claude/agents ~/.claude/skills
cp agents/*.md ~/.claude/agents/ && cp -R skills/* ~/.claude/skills/
```

Restart Claude Code, then run `/agents` to confirm they loaded. `cp` overwrites same-named files, so back up any existing agents first. To install for one project only, copy into that project's `.claude/agents/` and `.claude/skills/` instead. The consult agents also need their CLIs; see [Requirements](#requirements).

## What's Inside

### Auditor Agents

Run these after a change, or ask for one by name. Each reports findings only; Claude makes the fixes.

| Agent | What it does | Triggers on |
|-------|--------------|-------------|
| [`security-auditor`](agents/security-auditor.md) | Severity-ranked security review of code, infrastructure and services: authn/authz, injection, crypto, secrets, supply chain, IaC and cloud IAM, CI/CD, AI/LLM integrations (prompt injection, RAG poisoning), OAuth/OIDC, multi-tenant data access, serverless and edge. | Security-relevant code changes, new Dockerfiles or pipelines, "review this for security" |
| [`accessibility-auditor`](agents/accessibility-auditor.md) | WCAG 2.2 analysis with 208 numbered code patterns, 21 ARIA widget patterns, framework checks (React/Next.js, Vue, Angular, Svelte, Astro), native mobile, email mode, axe-core and ACT rule cross-references, and WCAG-EM 2.0 methodology. | New templates, forms, modals, custom widgets, color or CSS changes |
| [`code-quality-sweeper`](agents/code-quality-sweeper.md) | Pre-production completeness audit of an entire codebase: README features vs. real implementation, UI → API → database chains, stubs and dead code, env vars, dependencies, and IaC drift (Terraform, CDK, Helm, Kubernetes, GitHub Actions, CloudFormation, Pulumi and more). Resumable on large repos, with a machine-readable summary for CI gating. | "Make sure nothing is half-implemented before we ship" |

### Consult Agents (OpenAI, Google, xAI)

Each wraps a vendor CLI, sends a focused briefing, and returns the other model's analysis to Claude. None of them write final code.

| Agent | Backend | Best for |
|-------|---------|----------|
| [`openai`](agents/openai.md) | `codex` CLI: **GPT-6.2 Sol** by default, **GPT-6.2 Astra** for requested security audits, Daybreak Blue for defensive cybersecurity work | Architecture and tradeoff analysis, root-cause debugging hypotheses, research that needs reasoning and live web evidence together, security audits |
| [`google`](agents/google.md) | Antigravity CLI `agy` (Gemini 3.1 Pro), the successor to the `gemini` CLI | Grounded web research, current documentation and best practices, anything about Google products |
| [`xai`](agents/xai.md) | `grok` CLI: Grok 4.7 on AWS Bedrock, plus an optional live-X lane through a grok.com login | Cheap, fast, high-volume work: batch classification and extraction, log and corpus triage, tool-calling sweeps over local files |

How the consult agents behave:

- **Plan first, then API key.** The `openai` agent tries your ChatGPT plan first, falls back to a per-run API key only when the plan doesn't offer the model, and flags every pay-per-token run with a capitalized warning line.
- **Model routing is explicit.** Every invocation pins the model and reasoning effort, so a config change or a new CLI default can't silently switch models.
- **Known gaps are written down.** For example, Bedrock-hosted Grok has no live web search and will invent results if asked, so the `xai` agent sends live-data questions to the `google` or `openai` agent instead of answering from training data.

### Skills

| Skill | What it does |
|-------|--------------|
| [`documenting-project-context`](skills/documenting-project-context/SKILL.md) | Keeps a project's `CLAUDE.md` short and useful across sessions: what belongs there and what goes in path-scoped rules, skills, hooks or `docs/` files, plus compression rules, structure templates, and good and bad examples. Triggers on "update CLAUDE.md", "document this", or when a correction would otherwise be repeated next session. |

### Context Guides

Long-form references to load into a session, or to read when building your own.

| Guide | Size | Covers |
|-------|------|--------|
| [Creating Agent Skills](context/creating-a-new-skill/SKILL.md) | ~2,400 lines | The [agentskills.io](https://agentskills.io) open standard, Claude Code skill structure, YAML frontmatter fields, invocation control, string substitutions, dynamic context injection, progressive disclosure, security and cross-tool compatibility |
| [MCP Development Guide](context/mcp/MCP.md) | ~3,300 lines | Python MCP servers and clients on protocol `2026-07-28` and the official SDK v2 (`MCPServer`): the stateless design, `server/discover`, Streamable HTTP and stdio transports, subscriptions, multi round-trip requests, caching hints, error codes, and a legacy appendix |

### Helper Scripts

| Script | What it does |
|--------|--------------|
| [`bin/daybreak.sh`](bin/daybreak.sh) | A one-shot OpenAI Responses API call under the Daybreak Blue cyber access program, used by the `openai` agent for defensive security work. It reads the key from the macOS Keychain per run and passes it to `curl` on stdin, never in argv or the environment. Install: `install -m 755 bin/daybreak.sh ~/.claude/agents/bin/` |

## Usage

Claude Code picks an agent automatically when a request matches its `description`; you can also ask for one by name:

```text
> Review the new login endpoint for security issues
> Use the accessibility-auditor on the checkout form
> Ask the openai agent whether we should split this service, and why
> Have the google agent find the current Vertex AI auth docs
> Use the xai agent to bucket these 300 log files by root cause
```

Tips:

- **Auditors work best on a scoped target.** Name the files, directory or diff to review; the sweeper is designed for whole repositories and can take a while.
- **Consults need a briefing, not a file dump.** The agents tell the other model what was already ruled out and what kind of answer to return, and you get back a summary.
- **Agents run with `model: claude-opus-5-5`.** Change the `model:` line in a file's frontmatter to `sonnet`, `haiku` or `inherit` to trade depth for cost.

## Requirements

The auditor agents and the skill need only Claude Code. Each consult agent needs its CLI on `PATH` and an account:

| Agent | CLI | Account / auth |
|-------|-----|----------------|
| `openai` | [`codex`](https://github.com/openai/codex) (`npm install -g @openai/codex`) | A ChatGPT plan login (`codex login`), and optionally `OPENAI_API_KEY` for models the plan doesn't serve |
| `google` | Antigravity CLI `agy` | A Google account or a Vertex AI project (set your project ID where the file shows `<your-vertex-project>`) |
| `xai` | `grok` CLI | An AWS Bedrock API key with Grok access; optionally a grok.com login for the live-X lane |

Exact versions, flags and the gotchas each one was verified against are in the agent files themselves.

## Security Model

Anything a consult agent's commands print is sent to that vendor, so the agents are built to keep secrets out of it:

- **Empty environment.** `codex` is launched with `env -i` (only `PATH` and `HOME`), because a single tool that prints its environment would otherwise send every exported credential along. Name-based secret filters don't stop that.
- **One credential per run.** A per-run API key is the only variable added, and never the shell's own key variable.
- **Isolated home.** The `xai` agent runs `grok` with `HOME` pointed at a separate consult directory holding only its config and a symlinked login, so your global instructions don't ride along into the consult.
- **Read-only by default.** Consults run with read-only sandboxes, and the auditors report findings instead of editing code.

If you adapt these agents, keep those rules, and never put credentials, `.env` contents or auth files in a briefing.

## Repository Layout

```text
agents/     Subagent definitions (one .md file each, YAML frontmatter + system prompt)
skills/     Skills (one directory per skill, entry point SKILL.md)
context/    Long-form reference guides
bin/        Helper scripts used by the agents
```

## Staying Current

This repo is updated whenever an agent, skill or guide changes: new model releases, CLI flag changes, and gotchas found in real use. To update:

```bash
cd ai-skills-agents-context && git pull
cp agents/*.md ~/.claude/agents/ && cp -R skills/* ~/.claude/skills/
```

The [commit history](https://github.com/ventz/ai-skills-agents-context/commits/main) is the changelog; each commit says what changed and why. Watch the repo (Watch → Custom → Releases or All activity) to hear about updates.

## Contributing

Issues and pull requests are welcome, especially reports of an agent missing something it should catch, a CLI flag that has changed, or a model or price that is out of date. Keep each change focused on one agent or guide, and say how you verified it.

## License

[MIT](LICENSE) © Ventz Petkov
