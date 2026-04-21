# Copilot Instructions — vault-tutorial

## Project Overview

This is an interactive HashiCorp Vault tutorial website built with **VitePress** (Markdown-driven static site generator) and **Killercoda** (cloud sandbox provider). The tutorial content is written in Chinese (zh-CN).

- **Frontend**: VitePress site under `docs/`, deployed to GitHub Pages via GitHub Actions.
- **Sandbox scenarios**: Killercoda scenario definitions under `vault-tutorial/`, each providing a real Linux terminal with Vault pre-installed.
- **CI/CD**: `.github/workflows/deploy.yml` — pushes to `main` trigger `npm run build` → deploy to GitHub Pages.

## Repository Structure

```
docs/                              # VitePress content (Markdown files)
  index.md                         # Homepage (layout: home), NOT a tutorial chapter
  public/                          # Static assets copied as-is to build output root
  .vitepress/
    config.mjs                     # VitePress config (sidebar auto-managed, sitemap enabled)
    theme/
      index.js                     # Custom theme — registers global Vue components
      Layout.vue                   # Injects SponsorBanner on home page and doc pages
    components/
      KillercodaEmbed.vue          # <KillercodaEmbed> component (link button, NOT iframe)
      SponsorBanner.vue            # Global sponsor/credit banner (Killercoda acknowledgement)

vault-tutorial/                    # Killercoda scenario definitions
  structure.json                   # Lists all scenarios for Killercoda discovery
  <scenario-name>/                 # One directory per scenario
    index.json                     # Scenario metadata, step list, asset mapping
    init/
      background.sh                # Silent setup (sources setup-common.sh)
      foreground.sh                # User-facing progress messages
      init.md                      # Intro page shown before Step 1
    step1/text.md                  # Each step is a directory with text.md
    finish/finish.md               # Completion page
    assets/
      setup-common.sh              # AUTO-GENERATED — do not edit

scripts/
  setup-common.sh                  # Shared setup functions (SOURCE OF TRUTH)
  sync-setup-common.mjs            # Copies setup-common.sh into every scenario's assets/
  sync-sidebar.mjs                 # Auto-generates sidebar from docs/*.md frontmatter

.github/workflows/deploy.yml      # GitHub Pages deployment pipeline
```

## Key Conventions

### Adding a New Tutorial Chapter

Every tutorial chapter MUST have a corresponding Killercoda hands-on scenario under `vault-tutorial/`. The tutorial page (`docs/<slug>.md`) provides the reading material, and the Killercoda scenario provides the interactive lab environment. They always come in pairs — do NOT create a tutorial chapter without its Killercoda scenario, and vice versa.

1. Create `docs/<slug>.md` with required frontmatter:
   ```markdown
   ---
   order: <number>       # Sidebar sort order (lower = higher)
   title: <display text> # Sidebar label (falls back to first H1 heading)
   ---
   ```
   **File naming**: Do NOT put sequence numbers in the filename (e.g. use `vault-kv.md`, NOT `01-vault-kv.md`). Chapter ordering is controlled solely by the `order` field in frontmatter.
2. Create the matching Killercoda scenario under `vault-tutorial/<scenario-name>/` (see "Adding a New Killercoda Scenario" below).
3. Link to the sandbox at the end of the tutorial page:
   ```markdown
   <KillercodaEmbed src="https://killercoda.com/vault-tutorial/course/vault-tutorial/<SCENARIO_NAME>" title="实验标题" />
   ```
4. Run `npm run sync-sidebar` (or it runs automatically during `npm run build` via the `prebuild` hook).

### Adding a New Killercoda Scenario

1. Create a new directory under `vault-tutorial/<scenario-name>/`.
2. Add the scenario to `vault-tutorial/structure.json`.
3. Every scenario MUST use the standard directory layout (init/, step*/, finish/, assets/).
4. The `init/background.sh` should source `/root/setup-common.sh` and call shared functions.
5. The `init/foreground.sh` polls `while [ ! -f /tmp/.setup-done ]` and prints progress messages.

#### Scenario Directory Layout

```
vault-tutorial/<scenario-name>/
  index.json                     # Scenario metadata, step list, asset mapping
  init/
    background.sh                # Silent setup (sources setup-common.sh)
    foreground.sh                # User-facing progress messages
    init.md                      # Intro page shown before Step 1
  step1/text.md                  # Each step is a directory with text.md
  step2/text.md
  ...
  finish/finish.md               # Completion page
  assets/
    setup-common.sh              # AUTO-GENERATED — do not edit
```

#### `index.json` Template

```json
{
  "title": "场景标题（中文）",
  "description": "场景描述（中文）",
  "details": {
    "intro": {
      "text": "init/init.md",
      "background": "init/background.sh",
      "foreground": "init/foreground.sh"
    },
    "steps": [
      { "title": "步骤标题", "text": "step1/text.md" }
    ],
    "finish": {
      "text": "finish/finish.md"
    },
    "assets": {
      "host01": [
        { "file": "setup-common.sh", "target": "/root", "chmod": "+x" }
      ]
    }
  },
  "backend": {
    "imageid": "ubuntu"
  },
  "interface": {
    "layout": "editor-terminal"
  }
}
```

#### `background.sh` Pattern

```bash
#!/bin/bash
source /root/setup-common.sh

install_vault
start_vault_dev   # starts Vault in dev mode; sets VAULT_ADDR and VAULT_TOKEN

finish_setup      # MUST be called last — touches /tmp/.setup-done
```

#### `foreground.sh` Pattern

```bash
#!/bin/bash

echo "等待环境初始化..."
while [ ! -f /tmp/.setup-done ]; do
  sleep 1
done

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'

echo "export VAULT_ADDR='http://127.0.0.1:8200'" >> /root/.bashrc
echo "export VAULT_TOKEN='root'" >> /root/.bashrc

echo ""
echo "✅ 环境已就绪！Vault Dev 服务器已启动。"
echo ""
vault status
```

### Shared Setup Script (`setup-common.sh`)

- **Source of truth**: `scripts/setup-common.sh` — edit ONLY this file.
- **Auto-copied**: `scripts/sync-setup-common.mjs` copies it into every scenario's `assets/`.
- Available functions:
  - `install_vault` — downloads and installs the Vault binary (version controlled by `VAULT_VERSION` env var, default `1.19.2`).
  - `start_vault_dev` — starts Vault in dev mode (`-dev-root-token-id=root`), exports `VAULT_ADDR` and `VAULT_TOKEN`.
  - `finish_setup` — touches `/tmp/.setup-done` to signal foreground.sh that setup is complete.
- Do NOT edit `vault-tutorial/*/assets/setup-common.sh` directly — it is auto-generated.

### Sidebar Auto-Sync

- The sidebar in `config.mjs` is managed by `scripts/sync-sidebar.mjs`.
- The managed region is delimited by `// @auto-sidebar-start` and `// @auto-sidebar-end`.
- Do NOT remove or modify these markers.

### SponsorBanner

- `SponsorBanner.vue` renders a global acknowledgement crediting Killercoda for providing the free interactive lab environment.
- It is injected via `Layout.vue` into two slots: `#home-features-before` (homepage) and `#doc-before` (all doc pages).
- Do NOT remove it or replace it with a different component.

## Build & Development Commands

| Command | Purpose |
|---------|---------|
| `npm run dev` | Start VitePress dev server with hot reload |
| `npm run build` | Production build (auto-runs prebuild: sidebar sync + setup sync) |
| `npm run preview` | Preview the production build locally |
| `npm run sync-sidebar` | Manually sync sidebar config from `docs/*.md` frontmatter |
| `npm run sync-setup` | Manually copy `scripts/setup-common.sh` into every scenario's `assets/` |

## Things to Avoid

- Do NOT edit the sidebar block in `config.mjs` by hand.
- Do NOT remove the `// @auto-sidebar-start` / `// @auto-sidebar-end` markers.
- Do NOT skip the `touch /tmp/.setup-done` signal at the end of `background.sh` (call `finish_setup`).
- Do NOT use flat step files (`step1.md`) — must be `step1/text.md` directory format.
- Do NOT edit `vault-tutorial/*/assets/setup-common.sh` directly — it is auto-generated.
- Do NOT use Vault dev mode in production scenarios — it is for learning only (in-memory, no persistence).
- Do NOT mention "环境正在初始化，请稍候..." in `init.md` - The student would be confused by two different "initialization" messages (one in foreground.sh, one in init.md). The init.md should be a static introduction to the scenario, without dynamic progress messages.
