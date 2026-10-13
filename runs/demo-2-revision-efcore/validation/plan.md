# Validation: plan

**Verdict: pass** (0 blocking, 3 advisory). Revision feedback validated.

| Mandatory topic | Status | Where |
|---|---|---|
| EF Core performance | covered | Day 1 (row 1); revised Day 2 (row 2) and Day 5 (row 8) |
| Query optimization | covered | Day 2 (row 3); Day 5 revision and mock |
| AsNoTracking | covered | Day 3 (row 4); Day 5 revision recall and mock |
| N+1 queries | covered | Day 3 (row 5) + Day 5 (row 7); Day 5 mock |
| Indexing | covered | Day 4 (row 6); Day 5 revision and mock |

**Budget:** 30+5+25+15+15+30+15+15 = 150 min = 2.5 h. Five days of exactly 30 min each. Every per-topic theory/practice/interview breakdown adds up to its row.

**Revision feedback:**
- R-P1 applied: the Day 2 cross-reference to Day 4 is gone. The paging `SET STATISTICS IO` run appears only under *Optional Extensions*.
- R-P2 applied: AsNoTracking moved to Day 3, with recall questions in the Day 5 revision.
- R-P3 applied: row 2, the Day 2 theory note, and *Revision and Mock Interviews* all put the revision at the start of Day 2.
- R-P4 applied: there is a new "How priorities and time allocations were determined" section.
- All constraints are preserved: all 5 topics, 150 minutes, a hands-on focus, short questions, and only URLs from research.

**Personalization:** All 14 requirement assumptions are repeated, the questions are pitched at Middle+, and coverage advisories C1 and C2 are handled.

## Blocking findings
None.

## Advisory findings (owner: study-planner)
- **P1:** The "about 70% hands-on per topic" claim does not match the plan's own minutes: 53-67% per topic, about 64% overall.
- **P2:** The "10-15% target" for revision and mock time has no stated origin in the requirements or research.
- **P3:** "N+1 is the most common hidden EF performance bug" is not supported by research.

## Unverified claims
No Microsoft Learn pages were fetched. The plan's factual claims match the validated research.
