# Metr

## What This Is

Metr is a free, open-source system monitor for macOS (Apple Silicon only). It covers CPU, memory, disk, processes, network, GPU and temperatures/fans. It lives in the menu bar as three tiny ring gauges (CPU · RAM · Disk). Clicking them opens a panel that shows the details at a glance, and a full window is there when you want more. It should look and feel as if Apple made it, be super simple and intuitive, and work well with zero configuration.

## Core Value

Within two seconds of clicking, you know **exactly how much is being used** (exact numbers) and **who is using it** (which app/process). It looks indistinguishable from a first-party Apple app while doing so.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Menu bar item showing three small live ring gauges: CPU, RAM, Disk
- [ ] Click on menu bar item opens a native panel with exact numbers for every metric
- [ ] Panel shows top resource-consuming processes (who's eating CPU/RAM right now)
- [ ] User can force quit a process from the process list
- [ ] Full window app (Activity Monitor replacement, but simpler and prettier) for detailed view
- [ ] CPU usage (overall and meaningful breakdown for Apple Silicon, e.g. P/E cores)
- [ ] Memory usage (used / available / pressure)
- [ ] Disk usage (space used/free per volume)
- [ ] Network throughput (upload/download in real time)
- [ ] GPU usage (Apple Silicon)
- [ ] Temperatures and fan RPM (where available on Apple Silicon)
- [ ] Liquid Glass / macOS 26 native design — pixel-perfect Apple look
- [ ] UI localized in English and Spanish (follows system language)
- [ ] Minimal settings: sensible defaults, works great without touching anything
- [ ] Public GitHub repo with README, screenshots and an unsigned .dmg release

### Out of Scope

- Intel Macs — Apple Silicon only; simplifies sensor access and lets us use Apple Silicon–specific metrics
- macOS < 26 — need the current Liquid Glass design language to be "made by Apple"
- Battery / energy monitoring — not chosen for v1
- Code signing & notarization — requires paid Apple Developer account; v1 ships unsigned .dmg (users open via right-click)
- Homebrew cask — official casks require notarization; revisit if signing is added
- Heavy configurability (iStat-style dozens of options) — explicitly what the user dislikes in existing tools
- Desktop / Notification Center widgets — not chosen for v1
- Paid features / monetization — free and open source

## Context

- **Motivation:** existing options all fall short:
  - Activity Monitor is ugly and dense, and hard to read at a glance.
  - iStat Menus is good but paid.
  - Stats (free) doesn't look or feel like Apple made it.
  - All of them have too many options.
- **Usage pattern:** a quick glance from the menu bar (rings → click → panel) day to day, and a full window for deeper inspection.
- **Glance priorities:** "Who's consuming?" and "exact numbers". A green/yellow/red health status and trend sparklines were not prioritized (sparklines may still fit if they stay unobtrusive).
- **Platform:** Apple Silicon Macs on macOS 26 (Tahoe) or later. Temperature/fan readings on Apple Silicon rely on SMC/IOKit/HID sensors that are not officially documented, so expect research and best-effort coverage.
- **Distribution:** GitHub, unsigned .dmg. Free and open source.
- **Name:** Metr. The working directory is `monitor_recursos`.

## Constraints

- **Platform**: Apple Silicon only, macOS 26+ — native Liquid Glass look; Apple Silicon sensor/metric access
- **Design**: Must look and behave like a first-party Apple app (HIG, SF Symbols, system materials, native controls) — this is the product's identity
- **Simplicity**: Minimal settings; defaults must be right — the user explicitly rejects configuration overload
- **Performance**: A monitor must be lightweight itself (low CPU/RAM footprint), otherwise it pollutes what it measures
- **Budget**: $0 — no Apple Developer Program; unsigned distribution
- **Localization**: English + Spanish

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Menu bar + full window (both) | Quick glance daily + detail when needed | — Pending |
| Menu bar shows 3 ring gauges (CPU, RAM, Disk) | User wants "rueditas"; visual and compact | — Pending |
| Apple Silicon only | Simplifies; enables AS-specific metrics (P/E cores, GPU) | — Pending |
| macOS 26+ minimum | Required for current Liquid Glass design | — Pending |
| Process list: view + force quit | Answer "who's consuming" and act on it | — Pending |
| Unsigned .dmg on GitHub | Free; avoid $99/yr developer fee | — Pending |
| Name: Metr | User's choice | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-10-22 after initialization*
