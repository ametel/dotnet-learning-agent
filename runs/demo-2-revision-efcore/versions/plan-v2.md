---
artifact: plan
run_id: 20261012-193618-middle-backend-efcore-06d058
generated_by: study-planner
budget_hours: 2.5
planned_hours: 2.5
research_inputs:
  - research/data.md
---

# Study Plan: Middle+ .NET Backend, EF Core Performance in 5 days (interview in 7 days)

## Summary
This plan prepares a Middle+ .NET backend developer for a technical interview in about 7 days. It covers only the stated gap, EF Core performance, through the five requested topics: EF Core performance, Query optimization, AsNoTracking, N+1 queries, and Indexing. The schedule uses the full 2.5-hour budget as five study days of exactly 30 minutes, all in the same small console app. AsNoTracking comes on Day 3 so that Day 5 can review it. N+1 queries is split between Day 3 (the N+1 loop and its fixes) and Day 5 (cartesian explosion and split queries). 130 minutes (86.7%) go to the five topics and 20 minutes (13.3%) to spaced revision and a mock interview. The questions are pitched at practical trade-offs and diagnosis rather than definitions, because the role is Middle+.

## Assumptions
Repeated from *Open Questions and Assumptions* in `requirements.md`:
- **Interview date:** about 7 days after the run date, around 2026-10-19 (assumption 1).
- **Study days:** 5 study days before the interview, with 2 slack days for rest or overflow (assumption 2). Overflow must not push the total past 2.5 hours.
- **Seniority:** "Middle+", read as between middle and senior. Expect practical trade-off and diagnosis questions, not architecture leadership (assumption 3). Research leans its questions toward the upper end of Middle+.
- **Strengths:** unclear. General .NET backend knowledge is assumed adequate, so nothing outside EF Core performance is scheduled (assumptions 4 and 11).
- **Tools:** free resources and a local setup (.NET SDK plus a local database) are acceptable (assumption 5). Research uses SQL Server LocalDB or Docker, and SSMS for execution plans.
- **Company and format:** a generic .NET backend technical interview with verbal questions and possibly a short coding or code-review task (assumptions 6 and 7).
- **Versions:** latest LTS .NET with the matching EF Core (assumption 8). Research assumes EF Core 10 on .NET 10.
- **Database provider:** relational, with SQL Server as the example (assumption 9). `IncludeProperties`, the `[Url] IS NOT NULL` filter syntax, SSMS plans, and `SET STATISTICS IO` are SQL Server-specific. Other providers, such as PostgreSQL `EXPLAIN ANALYZE`, were not researched.
- **Language:** English materials (assumption 10).
- **Topic priorities:** all five stated and requested topics are High priority, and the derived support topic is Low (assumption 12). See *Time Budget* for how this turned into time allocations.
- **Derived optional topic:** "Inspecting the SQL that EF Core generates" gets no separate session. It is practiced inside the EF Core performance and Query optimization sessions (`LogTo`, `TagWithCallSite`, `ToQueryString`), as the coverage report notes (assumption 13).
- **Budget:** 2.5 hours is a hard cap, at most 30 minutes per day (assumption 14).

Planning assumptions and research gaps:
- **Setup time is part of Day 1.** The shared console app (Blog/Post/Contributor model, about 1,000 blogs with about 50 posts each, `LogTo(Console.WriteLine, LogLevel.Information)`) must be built inside the Day 1 practice block. Keep the seed code minimal. If setup overruns, cut the Day 1 dashboard method to two queries rather than going over 30 minutes.
- **The research exercises add up to about 110 minutes at full length** (20 + 25 + 15 + 25 + 25). Research says to pick from them rather than schedule them all in full, so each one is trimmed below. The trimmed parts are listed under *Optional Extensions*.
- **N+1 queries is split across two days.** No arrangement of five 30-minute days fits every topic whole while also putting AsNoTracking before the final day and keeping the mock interview on Day 5. The N+1 research exercise already has two separate parts (the N+1 loop, then cartesian explosion), so it is the natural topic to split: part 1 on Day 3, part 2 on Day 5.
- **Paging logical reads are not scheduled.** The `SET STATISTICS IO` comparison of offset and keyset paging from the Query optimization research exercise is left out of every scheduled day and listed under *Optional Extensions*. Day 2 measures paging with `Stopwatch` only.
- **Lazy loading and synchronous I/O (coverage advisory C1):** research says lazy loads are synchronous I/O, but the Learn page it cites does not state this. Use "hidden extra round trips" as the main argument against lazy loading in an API, and treat "synchronous I/O" as a supporting point you cannot cite.
- **AsNoTracking example (coverage advisory C2):** the research code example applies `AsNoTracking()` to a projection that has no entities, where it has no effect. This plan's AsNoTracking practice uses a query that returns entities, and treats the projection only as the "no AsNoTracking needed" contrast.
- **Logical-read numbers and plan-operator names** other than scan and seek in the research indexing example are illustrative. Measure your own values.
- **Sources:** all research sources are Microsoft Learn pages, mostly read through search excerpts. There are no non-Microsoft sources, for example on N+1 detection tooling.

## Time Budget
- **Budget:** 2.5 hours (150 minutes), confirmed by the user.
- **Planned:** 150 minutes = 2.5 hours, across 5 days of exactly 30 minutes.
- **Days:**
  - Day 1 = row 1 (30 min)
  - Day 2 = rows 2–3 (5 + 25 min)
  - Day 3 = rows 4–5 (15 + 15 min)
  - Day 4 = row 6 (30 min)
  - Day 5 = rows 7–8 (15 + 15 min)

  Every day falls before the interview, and 2 slack days remain.
- **Split per topic:**
  - EF Core performance: 30 min (Day 1: setup and diagnosis practice)
  - Query optimization: 25 min (Day 2)
  - AsNoTracking: 15 min (Day 3)
  - N+1 queries: 30 min (15 on Day 3, 15 on Day 5)
  - Indexing: 30 min (Day 4)
  - Revision: 10 min (5 at the start of Day 2, 5 on Day 5)
  - Mock interview: 10 min (Day 5)
- **Revision and mock share:** 20 of 150 minutes, or 13.3%.
- About 70% of each topic session is hands-on practice, which matches the stated preference for hands-on exercises and short questions.

**How priorities and time allocations were determined:**
1. **Priority.** `requirements.md` rates all five mandatory topics High (assumption 12): EF Core performance is the user's only stated gap, and the other four are explicit requests. The user gave no ranking among them, so no topic is dropped or reduced to a brief review. The derived support topic (inspecting generated SQL) is Low and gets no separate session (assumption 13). Nothing outside EF Core performance is scheduled (assumption 4).
2. **Reserve for revision and the mock first.** 20 of 150 minutes (13.3%) are set aside, within the 10–15% target. That leaves 130 minutes for the five topics.
3. **Allocate by the research exercise sizes.** Research sizes the exercises at about 20 (EF Core performance), 25 (Query optimization), 15 (AsNoTracking), 25 (N+1 queries), and 25 (Indexing) minutes, about 110 in total. Each topic also needs about 5 minutes of theory and 5 of interview drills, which brings the full total over 130. So each exercise was trimmed toward its research size, with these adjustments:
   - **EF Core performance gets 30 minutes** although its exercise is the smallest of the four larger ones, because Day 1 also has to build and seed the shared console app that every later day uses.
   - **N+1 queries and Indexing get 30 minutes each,** close to their full 25-minute exercises plus theory and questions. Research lists N+1 round trips and missing or unusable indexes among the usual root causes of slow EF data access, and both exercises need a before-and-after measurement to mean anything.
   - **Query optimization gets 25 minutes.** Its practice is trimmed from 25 to 15 minutes by dropping the SSMS logical-read run for paging. The projection comparison and the `Stopwatch` paging timing remain.
   - **AsNoTracking gets 15 minutes,** the smallest share, because its research exercise is already sized at 15 minutes and its ideas overlap with projection (Query optimization) and `Include` (N+1 queries).
4. **Order the days.** Day 1 (diagnosis) produces the suspects that later days fix. AsNoTracking comes on Day 3, not at the end, so that Day 5 can review it. Indexing keeps a whole day because its SSMS work does not split well, and N+1 queries is split along its two exercise parts (see *Assumptions*).

## Schedule
| # | Week | Topic | Activities | Minutes | Sources |
|---|---|---|---|---|---|
| 1 | 1 | EF Core performance | theory, practice, interview | 30 | https://learn.microsoft.com/ef/core/performance/performance-diagnosis ; https://learn.microsoft.com/ef/core/querying/tags |
| 2 | 1 | Revision: EF Core performance diagnosis questions (start of Day 2) | revision | 5 | https://learn.microsoft.com/ef/core/performance/performance-diagnosis |
| 3 | 1 | Query optimization | theory, practice, interview | 25 | https://learn.microsoft.com/ef/core/performance/efficient-querying ; https://learn.microsoft.com/ef/core/querying/pagination |
| 4 | 1 | AsNoTracking | theory, practice, interview | 15 | https://learn.microsoft.com/ef/core/querying/tracking ; https://learn.microsoft.com/ef/core/change-tracking/identity-resolution#identity-resolution-and-queries |
| 5 | 1 | N+1 queries | theory, practice | 15 | https://learn.microsoft.com/ef/core/performance/efficient-querying#load-related-entities-eagerly-when-possible ; https://learn.microsoft.com/ef/core/querying/related-data/lazy#lazy-loading-with-proxies |
| 6 | 1 | Indexing | theory, practice, interview | 30 | https://learn.microsoft.com/ef/core/modeling/indexes ; https://learn.microsoft.com/ef/core/performance/performance-diagnosis#inspecting-query-execution-plans |
| 7 | 1 | N+1 queries | practice, interview | 15 | https://learn.microsoft.com/ef/core/querying/single-split-queries#performance-issues-with-single-queries ; https://learn.microsoft.com/ef/core/querying/single-split-queries#enabling-split-queries-globally |
| 8 | 1 | Final revision (including AsNoTracking recall) and mock interview (all topics) | revision, mock | 15 | https://learn.microsoft.com/ef/core/performance/efficient-querying ; https://learn.microsoft.com/ef/core/querying/tracking |

## Topic Plans

### EF Core performance
- **Why it matters for this role:** This is the user's only stated weak area. A Middle+ backend interviewer expects a measure-first diagnosis workflow, not jumping straight to "use Dapper" or "add caching".
- **Theory (5 min, Day 1):**
  - Measure before optimizing. Public benchmarks rarely match real latency and data volume. ([Introduction to Performance](https://learn.microsoft.com/ef/core/performance/))
  - Diagnosis workflow: (1) command logging at `LogLevel.Information`, which gives `Executed DbCommand (Nms)` lines; (2) find the slow command or an unexpected number of round trips; (3) map SQL back to code with `TagWith` / `TagWithCallSite`; (4) analyze the execution plan. ([Performance Diagnosis](https://learn.microsoft.com/ef/core/performance/performance-diagnosis), [Query tags](https://learn.microsoft.com/ef/core/querying/tags))
  - Usual root causes: a missing or unusable index, loading too much data, N+1 round trips, cartesian explosion, and tracking overhead on large read-only results.
  - Keep command logging to short diagnostic windows or pre-production. Left on in production, it slows the app and fills disks. ([Simple Logging: filtering](https://learn.microsoft.com/ef/core/logging-events-diagnostics/simple-logging#filtering))
- **Practice (20 min, Day 1):**
  - Set up the shared console app: EF Core 10, SQL Server LocalDB or Docker, a `Blog`/`Post`/`Contributor` model, a seed of about 1,000 blogs × 50 posts, and `LogTo(Console.WriteLine, LogLevel.Information)`.
  - Write `GetDashboard()` with 3 or 4 queries, including one N+1 loop and one unbounded `ToList`. Tag each with `TagWithCallSite()`.
  - **Observe:** the number of `Executed DbCommand` lines, the slowest duration, and the source line each one came from. Write down your top 2 suspects before fixing anything. You will fix the unbounded `ToList` on Day 2 and the N+1 loop on Day 3.
- **Interview questions (5 min, Day 1):**
  1. *An endpoint got slow in production. How do you find out whether EF is the cause?* Strong answer covers: brief command logging or pre-production capture, per-command durations *and* command counts, `TagWith` to map SQL to code, then the execution plan, all before changing code.
  2. *A query is fast locally and slow in production. Why?* Strong answer covers: data volume changes the plan (scan versus seek), network latency multiplies round trips, and unbounded result sets.
  3. *When would you consider leaving LINQ for raw SQL?* Strong answer covers: only after measuring and after LINQ-level fixes (projection, indexes, split queries) have been tried.
- **Sources:** https://learn.microsoft.com/ef/core/performance/, https://learn.microsoft.com/ef/core/performance/performance-diagnosis, https://learn.microsoft.com/ef/core/querying/tags, https://learn.microsoft.com/ef/core/logging-events-diagnostics/simple-logging#filtering

### Query optimization
- **Why it matters for this role:** Projection, server-side filtering, and paging are the everyday fixes a Middle+ developer is expected to apply and explain, including how to check the generated SQL.
- **Theory (5 min, Day 2, after the opening revision):**
  - **Projection:** `Select` only the needed columns. Non-entity projections are not tracked, but you cannot `SaveChanges` on them. ([Efficient Querying](https://learn.microsoft.com/ef/core/performance/efficient-querying))
  - **Sargable filters:** keep `Where` on `IQueryable`. On SQL Server, `StartsWith` can use an index and `EndsWith` cannot. Wrapping the column (`ToLower()`, arithmetic, explicit `Collate`) generally prevents index use. The fix for case-insensitive search is the column collation. ([Collations and Case Sensitivity](https://learn.microsoft.com/ef/core/miscellaneous/collations-and-case-sensitivity#explicit-collation-in-a-query))
  - **Bound results** with `Take`.
  - **Pagination:** offset (`Skip/Take`) processes every skipped row and drifts under concurrent writes. Keyset (`Where(Id > lastId).OrderBy(Id).Take(n)`) is cheap with a matching index but has no random page jumps. The ordering must be unique. ([Pagination](https://learn.microsoft.com/ef/core/querying/pagination))
  - **Inspect SQL:** `ToQueryString()` shows the SQL without running it. ([What's New in EF Core 5.0](https://learn.microsoft.com/ef/core/what-is-new/ef-core-5.0/whatsnew#simple-logging-and-improved-diagnostics))
- **Practice (15 min, Day 2; trimmed from the 25-minute research exercise):**
  - Compare `ctx.Posts.ToListAsync()` with `Select(p => new { p.PostId, p.Title })`, and print `ToQueryString()` for both. Apply the projection and a `Take` to the unbounded `ToList` suspect from your Day 1 `GetDashboard()`.
  - Fetch page 2,000 with `Skip/Take`, then with keyset `Where(PostId > lastId)`, and time both with `Stopwatch`. The SSMS `SET STATISTICS IO` run for paging is not part of the scheduled plan. It is listed under *Optional Extensions*.
  - **Observe:** the column list in each SQL statement, and how elapsed time grows with the page number for offset paging but stays flat for keyset paging.
- **Interview questions (5 min, Day 2):**
  1. *What's wrong with `ctx.Posts.ToList().Where(p => p.Title.Contains(x))`?* Strong answer covers: it loads the whole table and filters on the client. Keep the query as `IQueryable` until the end.
  2. *Offset versus keyset pagination: trade-offs?* Strong answer covers: OFFSET cost grows with page number and pages drift under writes. Keyset is cheap with an index but has no random access. Ordering must be unique.
  3. *Why might `Where(p => p.Email.ToLower() == x)` be slow?* Strong answer covers: a function on the column is not sargable and blocks index use. Use the right column collation.
- **Sources:** https://learn.microsoft.com/ef/core/performance/efficient-querying, https://learn.microsoft.com/ef/core/querying/pagination, https://learn.microsoft.com/ef/core/what-is-new/ef-core-5.0/whatsnew#simple-logging-and-improved-diagnostics, https://learn.microsoft.com/ef/core/miscellaneous/collations-and-case-sensitivity#explicit-collation-in-a-query

### AsNoTracking
- **Why it matters for this role:** "When do you use AsNoTracking?" is a near-certain question. At Middle+ level the strong answer goes beyond "it's faster" to identity resolution and its trade-offs. It comes on Day 3 so that Day 5 can review it.
- **Theory (3 min, Day 3):**
  - Entity queries are tracked by default: snapshots, identity resolution, and navigation fix-up, which is what lets `SaveChanges` detect edits. `AsNoTracking()` skips this and is the right default for read-only paths. The context-wide default is `UseQueryTrackingBehavior(QueryTrackingBehavior.NoTracking)`, with `AsTracking()` per query. ([Tracking vs. No-Tracking Queries](https://learn.microsoft.com/ef/core/querying/tracking))
  - No-tracking does **no identity resolution**, so a shared principal in an `Include` produces duplicate instances. `AsNoTrackingWithIdentityResolution()` deduplicates. A tracking query can be cheaper when it reuses instances that are already tracked. ([Identity Resolution](https://learn.microsoft.com/ef/core/change-tracking/identity-resolution#identity-resolution-and-queries))
  - Projections without entity instances are untracked anyway, so `AsNoTracking()` adds nothing there. You saw such projections on Day 2. `DetectChanges` becomes a bottleneck only with thousands of tracked entities. ([Change Detection](https://learn.microsoft.com/ef/core/change-tracking/change-detection#snapshot-change-tracking))
- **Practice (8 min, Day 3; trimmed from the 15-minute research exercise):**
  - Load the 50,000 seeded posts as **entities** (`ctx.Posts.ToListAsync()`) with and without `AsNoTracking()`. Record time, `GC.GetTotalAllocatedBytes()`, and `ctx.ChangeTracker.Entries().Count()`.
  - Run `Include(p => p.Blog)` with `AsNoTracking()` and check with `ReferenceEquals` whether two posts of the same blog share a `Blog` instance. Repeat with `AsNoTrackingWithIdentityResolution()`.
  - **Observe:** tracked-entry count, time, allocations, and duplicate versus shared instances. Write the numbers down, because the Day 5 revision uses them.
- **Interview questions (4 min, Day 3):**
  1. *When would you use AsNoTracking, and when not?* Strong answer covers: read-only paths yes, entities you will modify no. Mention the context-wide default and `AsTracking`.
  2. *Can a no-tracking query be slower or behave differently?* Strong answer covers: no identity resolution gives duplicate instances, and `AsNoTrackingWithIdentityResolution` fixes that. Tracking can reuse instances that are already tracked.
  3. *Is a `Select` into a DTO tracked?* Strong answer covers: no, unless the projection contains entity instances.
- **Reviewed later:** Day 5 revision (row 8) and the Day 5 mock interview.
- **Sources:** https://learn.microsoft.com/ef/core/querying/tracking, https://learn.microsoft.com/ef/core/change-tracking/identity-resolution#identity-resolution-and-queries, https://learn.microsoft.com/ef/core/change-tracking/change-detection#snapshot-change-tracking

### N+1 queries
- **Why it matters for this role:** N+1 is the most common hidden EF performance bug and a frequent code-review interview task. Middle+ candidates are expected to detect it from logs and to know the trade-offs of each fix.
- **Split across two days:** part 1 (Day 3, row 5) covers the N+1 loop and its fixes. Part 2 (Day 5, row 7) covers cartesian explosion, split queries, and the interview questions.
- **Theory (5 min, Day 3):**
  - N+1: one query loads N parents, then navigation access in a loop adds one query per parent. Lazy loading hides this, and the docs recommend avoiding it. Lazy loading is opt-in: the Proxies package, `UseLazyLoadingProxies()`, and `virtual` navigations. Since EF8 it also works on no-tracking entities while their context is alive. ([Lazy Loading](https://learn.microsoft.com/ef/core/querying/related-data/lazy#lazy-loading-with-proxies), [What's New in EF Core 8](https://learn.microsoft.com/ef/core/what-is-new/ef-core-8.0/whatsnew#enhancements-to-lazy-loading))
  - Fixes: `Include`/`ThenInclude`, filtered include, or better, a projection that loads related data in one query. ([Efficient Querying: load related entities eagerly](https://learn.microsoft.com/ef/core/performance/efficient-querying#load-related-entities-eagerly-when-possible))
  - Preview for Day 5: cartesian explosion. `Include` on two sibling collections returns the cross product. `AsSplitQuery()` sends one query per collection, at the cost of extra round trips, no cross-query consistency without a transaction, and buffering. EF warns when multiple collections are loaded and no split mode is configured. ([Single vs. Split Queries](https://learn.microsoft.com/ef/core/querying/single-split-queries#performance-issues-with-single-queries), [Enabling split queries globally](https://learn.microsoft.com/ef/core/querying/single-split-queries#enabling-split-queries-globally))
  - Split queries with `Skip/Take` need a unique ordering. EF Core 10 fixed inconsistent ordering in split-query subqueries. ([What's New in EF Core 10](https://learn.microsoft.com/ef/core/what-is-new/ef-core-10.0/whatsnew#linq-and-sql-translation))
- **Practice, part 1 (10 min, Day 3):**
  - Turn on `UseLazyLoadingProxies()`, loop over blogs → posts (limit to the first 100 blogs to save time), and count the logged commands. Fix it with a projection, then with `Include`.
  - Apply the projection fix to the N+1 suspect from your Day 1 `GetDashboard()`.
  - **Observe:** commands per run (N+1 versus 1) and total time.
- **Practice, part 2 (10 min, Day 5):**
  - `Include` both `Posts` and `Contributors`, and note the row count and the multiple-collection warning. Add `AsSplitQuery()` and compare.
  - **Observe:** commands per run (1 versus 2 or 3), rows from the single JOIN versus the split queries, and total time.
- **Interview questions (5 min, Day 5):**
  1. *Explain N+1 and how you'd spot it.* Strong answer covers: navigation access per parent in a loop, logs showing N similar commands, and lazy loading hiding it.
  2. *What is cartesian explosion, and how do split queries help? What do they cost?* Strong answer covers: sibling collection JOINs multiply rows. A split query runs one query per collection. Costs: extra round trips, no cross-query consistency without a transaction, buffering.
  3. *Would you enable lazy loading in an ASP.NET Core API?* Strong answer covers: generally no, because of hidden round trips. Prefer explicit eager loading or projections. (See the C1 caveat under *Assumptions* about "synchronous I/O".)
- **Sources:** https://learn.microsoft.com/ef/core/performance/efficient-querying#load-related-entities-eagerly-when-possible, https://learn.microsoft.com/ef/core/querying/related-data/lazy#lazy-loading-with-proxies, https://learn.microsoft.com/ef/core/querying/single-split-queries#performance-issues-with-single-queries, https://learn.microsoft.com/ef/core/querying/single-split-queries#enabling-split-queries-globally, https://learn.microsoft.com/ef/core/what-is-new/ef-core-10.0/whatsnew#linq-and-sql-translation, https://learn.microsoft.com/ef/core/what-is-new/ef-core-8.0/whatsnew#enhancements-to-lazy-loading

### Indexing
- **Why it matters for this role:** Many EF performance problems are really index problems. Middle+ candidates should define indexes in the EF model and prove that one helps with a plan, not by guessing.
- **Theory (5 min, Day 4):**
  - Define indexes with `[Index(nameof(Url))]` or `HasIndex(...)`: composite, `IsUnique()`, `IsDescending(...)`, filtered with `HasFilter(...)`, and covering via `IncludeProperties(...)` (SQL Server). EF indexes foreign keys by convention. Indexes are applied through migrations. ([Indexes](https://learn.microsoft.com/ef/core/modeling/indexes), [Index filter and included columns](https://learn.microsoft.com/ef/core/modeling/indexes#index-filter))
  - Column order matters: (A, B) helps filters on A, or on A and B, but not on B alone. Match the sort order to the `ORDER BY`.
  - Every index slows writes and uses storage. Index measured hot queries only. ([Efficient Querying](https://learn.microsoft.com/ef/core/performance/efficient-querying))
  - Read plans in SSMS with *Include Actual Execution Plan*: scan versus seek, estimated versus actual rows. Pair this with `SET STATISTICS IO ON` logical reads. ([Inspecting query execution plans](https://learn.microsoft.com/ef/core/performance/performance-diagnosis#inspecting-query-execution-plans), [Display an actual execution plan](https://learn.microsoft.com/sql/relational-databases/performance/display-an-actual-execution-plan?view=sql-server-ver17), [SET STATISTICS IO](https://learn.microsoft.com/sql/t-sql/statements/set-statistics-io-transact-sql?view=sql-server-ver17))
- **Practice (20 min, Day 4; the `EndsWith` bonus is optional):**
  - Take the logged SQL for `Posts.Where(p => p.BlogId == x && p.PublishedOn > d).OrderBy(p => p.PublishedOn).Select(p => new { p.Title, p.PublishedOn })`. Run it in SSMS with the actual plan and `SET STATISTICS IO ON`.
  - Add `HasIndex(p => new { p.BlogId, p.PublishedOn }).IncludeProperties(p => p.Title)` through a migration, and rerun.
  - **Observe:** the scan-to-seek change, the drop in logical reads, and estimated versus actual rows. Use logical reads, not warm-cache elapsed time, as the evidence.
- **Interview questions (5 min, Day 4):**
  1. *You have an index on (LastName, FirstName). Which queries benefit?* Strong answer covers: filters on LastName or on both, not FirstName alone.
  2. *What is a covering index, and how do you define one in EF Core?* Strong answer covers: every column the query uses is in the index, so the table is not read. `HasIndex(...).IncludeProperties(...)` on SQL Server.
  3. *How do you prove an index helped?* Strong answer covers: the actual plan (seek versus scan, estimated versus actual rows) plus `SET STATISTICS IO` logical reads, before and after, on realistic data.
  4. *Why not index every column?* Strong answer covers: write overhead and storage, filtered indexes for subsets, and indexing only measured hot queries.
- **Sources:** https://learn.microsoft.com/ef/core/modeling/indexes, https://learn.microsoft.com/ef/core/modeling/indexes#index-filter, https://learn.microsoft.com/ef/core/performance/efficient-querying, https://learn.microsoft.com/ef/core/performance/performance-diagnosis#inspecting-query-execution-plans, https://learn.microsoft.com/sql/relational-databases/performance/display-an-actual-execution-plan?view=sql-server-ver17, https://learn.microsoft.com/sql/t-sql/statements/set-statistics-io-transact-sql?view=sql-server-ver17

## Revision and Mock Interviews
- **Day 2 opening revision (5 min, row 2):** This is the first block of Day 2, before you start Query optimization. Answer two Day 1 questions out loud from memory, without notes:
  - "An endpoint got slow in production. How do you find out whether EF is the cause?"
  - "Why shouldn't you leave EF command logging at Information level in production?" (Strong answer: overhead and log volume. Use short windows, sampling, or pre-production capture.)

  Check your answers against your Day 1 log notes.
- **Day 5 revision (5 min, row 8, after N+1 part 2):**
  - First, answer two AsNoTracking questions from Day 3 aloud without notes: *When would you use AsNoTracking, and when not?* and *Is a `Select` into a DTO tracked?* Check them against your Day 3 tracked-entry counts and `ReferenceEquals` results.
  - Then reread your "Observe" notes from Days 1–5: command counts, offset versus keyset timings, tracked-entry counts and allocations, N+1 versus split-query command counts, and logical reads before and after the index.
  - Pick one measured number per topic to quote in the interview.
- **Day 5 mock interview (10 min, row 8):** Answer one question per topic aloud, about 2 minutes each, timed. Use your own measurements as evidence.
  1. EF Core performance: *A query is fast locally and slow in production. Why?*
  2. Query optimization: *Offset versus keyset pagination: trade-offs?*
  3. AsNoTracking: *Can a no-tracking query be slower or behave differently?*
  4. N+1 queries: *Include versus projection for related data?* (Strong answer: `Include` loads full entities, tracked by default. A projection loads only the needed columns in one query and is better for read models.)
  5. Indexing: *How do you prove an index helped?*
  - Spare question for a code-review style finish: *What's wrong with `ctx.Posts.ToList().Where(p => p.Title.Contains(x))`?*
- During the 2 slack days, re-ask any mock question you answered weakly. This is optional and not part of the scheduled budget.

## Sources
- Introduction to Performance (EF Core): https://learn.microsoft.com/ef/core/performance/
- Performance Diagnosis (EF Core): https://learn.microsoft.com/ef/core/performance/performance-diagnosis
- Performance Diagnosis: inspecting query execution plans: https://learn.microsoft.com/ef/core/performance/performance-diagnosis#inspecting-query-execution-plans
- Efficient Querying (EF Core): https://learn.microsoft.com/ef/core/performance/efficient-querying
- Efficient Querying: load related entities eagerly: https://learn.microsoft.com/ef/core/performance/efficient-querying#load-related-entities-eagerly-when-possible
- Pagination (EF Core): https://learn.microsoft.com/ef/core/querying/pagination
- Query tags (EF Core): https://learn.microsoft.com/ef/core/querying/tags
- Simple Logging: filtering: https://learn.microsoft.com/ef/core/logging-events-diagnostics/simple-logging#filtering
- What's New in EF Core 5.0: simple logging and ToQueryString: https://learn.microsoft.com/ef/core/what-is-new/ef-core-5.0/whatsnew#simple-logging-and-improved-diagnostics
- Collations and Case Sensitivity: https://learn.microsoft.com/ef/core/miscellaneous/collations-and-case-sensitivity#explicit-collation-in-a-query
- Tracking vs. No-Tracking Queries: https://learn.microsoft.com/ef/core/querying/tracking
- Identity Resolution in EF Core: https://learn.microsoft.com/ef/core/change-tracking/identity-resolution#identity-resolution-and-queries
- Change Detection and Notifications: https://learn.microsoft.com/ef/core/change-tracking/change-detection#snapshot-change-tracking
- Lazy Loading of Related Data: https://learn.microsoft.com/ef/core/querying/related-data/lazy#lazy-loading-with-proxies
- Single vs. Split Queries: https://learn.microsoft.com/ef/core/querying/single-split-queries#performance-issues-with-single-queries
- Single vs. Split Queries: enabling globally: https://learn.microsoft.com/ef/core/querying/single-split-queries#enabling-split-queries-globally
- What's New in EF Core 10: split query ordering: https://learn.microsoft.com/ef/core/what-is-new/ef-core-10.0/whatsnew#linq-and-sql-translation
- What's New in EF Core 8: lazy-loading enhancements: https://learn.microsoft.com/ef/core/what-is-new/ef-core-8.0/whatsnew#enhancements-to-lazy-loading
- Indexes (EF Core modeling): https://learn.microsoft.com/ef/core/modeling/indexes
- Indexes: index filter and included columns: https://learn.microsoft.com/ef/core/modeling/indexes#index-filter
- Display an actual execution plan (SQL Server): https://learn.microsoft.com/sql/relational-databases/performance/display-an-actual-execution-plan?view=sql-server-ver17
- SET STATISTICS IO (Transact-SQL): https://learn.microsoft.com/sql/t-sql/statements/set-statistics-io-transact-sql?view=sql-server-ver17

## Optional Extensions
None of these is scheduled, because the 2.5-hour budget is fully used.
- **Trimmed exercise parts:**
  - The `SET STATISTICS IO` run for offset versus keyset paging (Query optimization). If you try it on a slack day, SSMS will already be set up from Day 4.
  - The full 50,000-row lazy-loading loop (N+1 queries).
  - The `Title.EndsWith(...)` bonus that shows the index being ignored (Indexing).
  - The extra `AsNoTracking` timing repeats.
- **Inspecting generated SQL (derived optional topic):** already practiced through `LogTo`, `TagWithCallSite`, and `ToQueryString`. No separate session is needed.
- **Buffering versus streaming (`ToListAsync` versus `AsAsyncEnumerable`):** suggested in the coverage report as a Middle+ talking point under Query optimization. The research artifact contains no findings on it, so this plan gives no content. Look it up in Efficient Querying (https://learn.microsoft.com/ef/core/performance/efficient-querying) if time allows.
- **`DetectChanges` question:** *What is DetectChanges, and when would you disable it?* Strong answer covers: snapshot comparison on `SaveChanges`/`Entries`. Disable it only when profiling shows a cost with thousands of tracked entities, and restore it in a `finally`.
- **Other providers:** PostgreSQL plan reading (`EXPLAIN ANALYZE`) was not researched. Add it only if the target company turns out to use a database other than SQL Server.
