# Validation: coverage

**Verdict: pass** (0 blocking, 2 advisory)

| Mandatory topic | Status | Research section (research/data.md) |
|---|---|---|
| EF Core performance | covered | EF Core performance: diagnosing and fixing slow data access |
| Query optimization | covered | EF Core query optimization: projections, filtering, pagination, and inspecting generated SQL |
| AsNoTracking | covered | AsNoTracking and change tracking costs in EF Core |
| N+1 queries | covered | N+1 queries in EF Core: lazy loading, Include, and split queries |
| Indexing | covered | Database indexing for EF Core queries: defining indexes and reading query plans |

Each section has Middle+/Senior findings, pitfalls, an example, 4 interview questions, and a sized hands-on exercise. All sources are on Microsoft Learn.

## Blocking findings

None.

## Advisory findings

- **C1 (data-researcher, traceability, N+1 queries):** "Lazy loads are always synchronous I/O" is cited to the Lazy Loading page. When fetched, that page does not say this. Cite a supporting page or soften the claim.
- **C2 (data-researcher, other, AsNoTracking):** The AsNoTracking example puts AsNoTracking on a projection that has no entities, so it has no effect there. Show it on an entity query instead.

## Optional recommendations

- The derived topic (inspecting generated SQL) is already covered inside Query optimization and EF Core performance.
- Optionally add buffering vs. streaming to Query optimization.

## Claim checks (3 of 5 fetches used)

- What's New in EF Core 10: the split-query ordering fix is **confirmed**. EF10 is an LTS release (Nov 2025), so the EF Core 10 / .NET 10 assumption holds.
- Efficient Querying: **confirmed** for StartsWith/EndsWith index use, composite index order, index write cost and filters, N+1 with lazy loading, cartesian explosion, and no-tracking identity duplication.
- Lazy Loading of Related Data: the proxies setup is **confirmed**. The "always synchronous" claim is **not supported** on this page (C1).
- Not fetched: the EF8 lazy loading for no-tracking entities, Attach-after-no-tracking wording, and SQL Server plan/STATISTICS IO pages. They look plausible and were not checked.
