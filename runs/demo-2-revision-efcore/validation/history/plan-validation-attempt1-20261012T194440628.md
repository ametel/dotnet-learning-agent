# Validation: plan

**Verdict: pass** (0 blocking, 4 advisory)

| Mandatory topic | Status | Where |
|---|---|---|
| EF Core performance | covered | Day 1 (30 min), Day 2 revision, mock Q1 |
| Query optimization | covered | Day 2 (25 min), Day 5 revision, mock Q2 |
| AsNoTracking | covered | Day 5 (15 min), mock Q3 |
| N+1 queries | covered | Day 3 (30 min), Day 5 revision, mock Q4 |
| Indexing | covered | Day 4 (30 min), Day 5 revision, mock Q5 |

Checks passed:
- **Time:** 150 min = 2.5 h budget. 5 days of exactly 30 min, inside the 7-day window with 2 slack days. Per-session minute splits add up.
- **Personalization:** Middle+ trade-off and diagnosis questions, hands-on practice in about 70% of each topic session, short questions with key points. No areas outside EF Core performance are scheduled.
- **Assumptions:** 1-11, 13, and 14 are restated, plus research gaps (C1 lazy-loading caveat, C2 AsNoTracking example fix, illustrative read counts).
- **Grounding:** every plan URL appears in research/data.md, and plan claims trace to research findings. No invented findings: the buffering topic is explicitly left without content.

## Blocking findings
None.

## Advisory findings (owner: study-planner)
- **P1** (Query optimization): Day 2 says the SET STATISTICS IO paging comparison "moves to Day 4", but Day 4 lacks it and Optional Extensions lists it as unscheduled.
- **P2** (AsNoTracking): it gets no spaced revision. The Day 5 revision covers only notes from Days 1-4.
- **P3:** the Day 2 revision text says "before the new topic", but the Schedule puts it after Query optimization.
- **P4:** assumption 12 (derived topic priorities) is not restated, although the time split depends on it.

## Claim verification
- Fetched https://learn.microsoft.com/ef/core/what-is-new/ef-core-10.0/whatsnew#linq-and-sql-translation. It confirms that EF10 made split-query subquery ordering consistent. (1 of 5 checks used.)
- The lazy-loading "synchronous I/O" claim (coverage C1) was not re-fetched. The plan already treats it as uncited and does not rely on it.
