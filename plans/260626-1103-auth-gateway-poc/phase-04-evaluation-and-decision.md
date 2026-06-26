---
phase: 04
title: Evaluation & decision
status: pending
priority: P0
effort: 0.5d
blockedBy: [02, 03]
---

# Phase 04 — Evaluation & Decision

## Context
- After 7-day soak of both POCs
- Brainstorm §4 lists 7 criteria

## Overview
Score both POCs against criteria, write decision doc, sketch production rollout for winner.

## Evaluation Criteria & Scoring

| # | Criterion | Weight | POC-A score | POC-B score | Notes |
|---|---|---|---|---|---|
| 1 | Onboard steps (new OIDC app) | High | | | count clicks + minutes |
| 2 | RAM/CPU steady-state | Medium | | | `docker stats` averaged over 7d |
| 3 | Forward-auth DX (headers, error pages) | High | | | qualitative + screenshot |
| 4 | Self-serve viability for other devs | High | | | hand to teammate, time them |
| 5 | Admin UI quality | Medium | | | qualitative |
| 6 | Docs & community signal | Medium | | | check GH issue response time, last release |
| 7 | Stability (restarts/crashes in 7d) | High | | | from compose logs |

Scoring: 1–5 each. Weighted total = winner.

## Deliverables
- `docs/poc-comparison-report.md` — filled scoring table + screenshots + recommendation
- `docs/auth-gateway-decision.md` — decision rationale, signed off by tech lead
- `docs/production-rollout-sketch.md` — for winner, covering:
  - HA (managed Postgres or replica, multiple gateway replicas)
  - Backup/DR strategy
  - Monitoring (Prometheus exporter? log shipping?)
  - Secret rotation policy
  - On-call runbook
  - App onboarding self-serve docs

## Implementation Steps
1. Collect metrics from both POCs (script: parse `docker stats` history, count log restart entries)
2. Time 1 unfamiliar dev onboarding a new sample app on each POC
3. Score table together (tech lead + 1 reviewer)
4. Write comparison report
5. Decision meeting: choose A or B
6. Sketch production rollout
7. Decide fate of losing POC: tear down or keep for reference?

## Todo
- [ ] Metrics collected (both POCs)
- [ ] Unfamiliar-dev onboarding test done (both POCs)
- [ ] Scoring table filled
- [ ] Comparison report written
- [ ] Decision doc signed off
- [ ] Production rollout sketch drafted
- [ ] Losing POC fate decided

## Success Criteria
- Clear, documented decision with traceable scoring
- Production rollout plan ready to convert into a follow-up `/ck:plan`

## Next Steps
- New plan: production rollout of winner
- New plan: migrate first 3 real internal apps onto the gateway
