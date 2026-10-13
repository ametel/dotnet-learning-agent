---
artifact: research
area: data
run_id: 20261012-193618-middle-backend-efcore-06d058
generated_by: data-researcher
assumed_versions: EF Core 10 on .NET 10 (current LTS), SQL Server 2022 or later via Microsoft.EntityFrameworkCore.SqlServer
---

# Research: EF Core, SQL and Data Access

## Scope

Assigned topics (all five map to the user's only stated gap, EF Core performance):

1. EF Core performance: diagnosing and fixing slow data access
2. EF Core query optimization: projections, filtering, pagination, and inspecting generated SQL
3. AsNoTracking and change tracking costs in EF Core
4. N+1 queries in EF Core: lazy loading, Include, and split queries
5. Database indexing for EF Core queries: defining indexes and reading query plans

**Level targeted:** Middle+ .NET backend. The requirements keep the user's word "Middle+", interpreted as "between middle and senior". The focus is practical trade-offs and diagnosis, not definitions and not architecture leadership. The agent brief says "Senior", so the questions lean toward the upper end of Middle+.

**Budget fit:** The user has 2.5 hours in total (30 minutes a day for 5 days) and prefers hands-on exercises and short questions. Each exercise below is sized for about 15 to 25 minutes, and all five can share one small sample project. The planner should pick from them, not schedule them all at full length.

**Assumptions (from requirements):** EF Core 10 / .NET 10 LTS. SQL Server is the example provider (LocalDB or Docker is fine), and provider-specific points are marked. Exercises use free tooling only.

**Deliberately left out:** compiled models and compiled queries in depth, DbContext pooling, bulk `ExecuteUpdate`/`ExecuteDelete`, raw SQL and Dapper comparisons, caching layers, Cosmos DB, concurrency tokens, migrations, and broader SQL Server tuning (statistics maintenance, Query Store administration).

## Findings

### EF Core performance: diagnosing and fixing slow data access
- **What a Senior is expected to know:**
  - Measure before optimizing. The EF docs open with "Identify bottlenecks and measure, measure, measure" and warn that public benchmarks rarely match real latency and data volumes.
  - The diagnosis workflow is: (1) turn on command logging at `LogLevel.Information` to get `Executed DbCommand (Nms)` lines with timings, (2) find the slow command or an unexpected *number* of commands (round trips), (3) map SQL back to code with `TagWith` / `TagWithCallSite`, (4) analyze the execution plan in the database.
  - The usual root causes are a missing or unusable index, loading too much data (full entities, no row limit), N+1 round trips, cartesian explosion from multiple collection `Include`s, and tracking overhead on large read-only result sets.
  - EF also exposes metrics for in-EF problems such as query-cache misses that cause constant recompilation, and leaked DbContexts.
  - Command logging is for short diagnostic windows or pre-production. Leaving it on in production slows the app and fills disks.
- **Common pitfalls / red flags in answers:**
  - Jumping to "use Dapper / raw SQL / add caching" with no measurement.
  - Testing on a near-empty dev database. Query plans depend on data volume, so a scan on 10 rows tells you nothing.
  - Not thinking about the number of round trips, only the duration of a single query.
- **Example:**
  ```csharp
  // Development-time: log every command with its duration
  optionsBuilder.UseSqlServer(conn)
                .LogTo(Console.WriteLine, LogLevel.Information);

  var top = await ctx.Orders
      .TagWithCallSite()                 // adds "-- file: ...cs:42" to the SQL
      .Where(o => o.CustomerId == id)
      .ToListAsync();
  // Log: Executed DbCommand (812ms) ... -- file: OrdersService.cs:42
  ```
- **Sources:** [Introduction to Performance](https://learn.microsoft.com/ef/core/performance/), [Performance Diagnosis](https://learn.microsoft.com/ef/core/performance/performance-diagnosis), [Query tags](https://learn.microsoft.com/ef/core/querying/tags), [Simple Logging: filtering](https://learn.microsoft.com/ef/core/logging-events-diagnostics/simple-logging#filtering)

### EF Core query optimization: projections, filtering, pagination, and inspecting generated SQL
- **What a Senior is expected to know:**
  - **Projection:** `Select` only the columns you need (an anonymous type or DTO). The SQL then lists only those columns. Projected non-entity results are not tracked, so you also avoid tracking cost. The trade-off is that you cannot `SaveChanges` on a projection.
  - **Filtering on the server:** keep `Where` on `IQueryable` so it becomes SQL. Filters must be *sargable*: `StartsWith` can use an index on SQL Server, `EndsWith` cannot. Wrapping the column in an expression (`price / 2`, `ToLower()`, an explicit `Collate`) generally prevents index use.
  - **Limit result size:** always bound results (`Take`). Test databases hide unbounded queries.
  - **Pagination:** offset paging (`Skip/Take` → `OFFSET`) still makes the database process every skipped row, and it can skip or duplicate rows under concurrent writes. Keyset (seek) paging (`Where(Id > lastId).OrderBy(Id).Take(n)`) is efficient with a matching index but supports no random page jumps. Ordering must be fully unique (for example Date plus Id).
  - **Inspect SQL:** `query.ToQueryString()` returns the SQL without running it. Logging shows the executed SQL and its timing.
- **Common pitfalls / red flags in answers:**
  - Calling `ToList()` / `AsEnumerable()` before `Where` or `Select`, so the filtering happens in memory.
  - Paging by `OrderBy(Date)` alone (non-unique), so rows go missing between pages.
  - "Case-insensitive search with `ToLower()`" without mentioning that it can kill index use. The fix is the right column collation.
- **Example:**
  ```csharp
  // Before: full entities, offset paging
  var page = await ctx.Posts.OrderBy(p => p.PostId).Skip(10_000).Take(20).ToListAsync();

  // After: projection + keyset paging (needs an index matching the ORDER BY)
  var q = ctx.Posts
      .Where(p => p.PostId > lastId)
      .OrderBy(p => p.PostId)
      .Select(p => new PostListItem(p.PostId, p.Title))
      .Take(20);
  Console.WriteLine(q.ToQueryString());   // SELECT TOP(@p) [p].[PostId], [p].[Title] ... WHERE [p].[PostId] > @lastId
  var page2 = await q.ToListAsync();
  ```
- **Sources:** [Efficient Querying](https://learn.microsoft.com/ef/core/performance/efficient-querying), [Pagination](https://learn.microsoft.com/ef/core/querying/pagination), [What's New in EF Core 5.0: simple logging and ToQueryString](https://learn.microsoft.com/ef/core/what-is-new/ef-core-5.0/whatsnew#simple-logging-and-improved-diagnostics), [Collations and Case Sensitivity](https://learn.microsoft.com/ef/core/miscellaneous/collations-and-case-sensitivity#explicit-collation-in-a-query)

### AsNoTracking and change tracking costs in EF Core
- **What a Senior is expected to know:**
  - Queries that return entity types are tracking by default. EF snapshots the original values, does identity resolution, and fixes up navigations. That is what lets `SaveChanges` detect and persist edits.
  - `AsNoTracking()` skips this setup. It is generally faster and the right default for read-only paths, such as GET endpoints and reports. You can make it context-wide with `UseQueryTrackingBehavior(QueryTrackingBehavior.NoTracking)` and opt back in per query with `AsTracking()`.
  - No-tracking queries do **no identity resolution**, so the same row appearing many times (for example a shared principal in an `Include`) yields duplicate instances. `AsNoTrackingWithIdentityResolution()` deduplicates with a stand-alone, throwaway tracker. A tracking query can even be cheaper when it reuses instances that are already tracked.
  - Projections that contain no entity instances are not tracked anyway. Projections that *do* contain entities (`new { Blog = b, ... }`) are tracked.
  - Snapshot change detection (`DetectChanges`) runs on `SaveChanges` and `ChangeTracker.Entries`. It only becomes a bottleneck with thousands of tracked entities. `AutoDetectChangesEnabled = false` is an optimization to justify by profiling, not a default.
- **Common pitfalls / red flags in answers:**
  - "AsNoTracking is always faster", with no mention of identity resolution or duplicate instances.
  - Querying with no-tracking and then routinely `Attach`ing results to update them. The docs call this slower and harder to get right than a tracking query.
  - Long-lived DbContexts accumulating tracked entities, leading to stale data and growing memory. Use a short-lived context per unit of work.
- **Example:**
  ```csharp
  // Read-only API endpoint
  var dto = await ctx.Blogs.AsNoTracking()
      .Where(b => b.Rating > 3)
      .Select(b => new { b.BlogId, b.Url })   // already untracked: no entity in the result
      .ToListAsync();

  // Update path: tracking is what you want
  var blog = await ctx.Blogs.SingleAsync(b => b.BlogId == id);
  blog.Rating = 5;
  await ctx.SaveChangesAsync();               // DetectChanges finds the modified property
  ```
- **Sources:** [Tracking vs. No-Tracking Queries](https://learn.microsoft.com/ef/core/querying/tracking), [Identity Resolution in EF Core](https://learn.microsoft.com/ef/core/change-tracking/identity-resolution#identity-resolution-and-queries), [Change Detection and Notifications](https://learn.microsoft.com/ef/core/change-tracking/change-detection#snapshot-change-tracking)

### N+1 queries in EF Core: lazy loading, Include, and split queries
- **What a Senior is expected to know:**
  - **N+1:** one query loads N parents, then accessing a navigation in a loop triggers one more query per parent. Lazy loading makes this invisible in code. The docs recommend avoiding lazy loading, because eager or explicit loading makes round trips visible.
  - Lazy loading is opt-in: the `Microsoft.EntityFrameworkCore.Proxies` package, `UseLazyLoadingProxies()`, and `virtual` navigations. Lazy loads are always synchronous I/O. Since EF8, lazy loading also works on no-tracking entities, as long as their context is alive.
  - **Fixes:** use `Include`/`ThenInclude` (eager loading), or better, a projection that pulls the related data in one query. Filtered include (`Include(b => b.Posts.Where(...))`) limits what is loaded.
  - **Cartesian explosion:** `Include`ing two sibling collections makes the single JOIN query return the cross product (10 posts × 10 contributors = 100 rows per blog). `AsSplitQuery()` issues one SQL query per collection instead. The trade-offs are more round trips, no consistency guarantee across queries without a snapshot/serializable transaction, and buffering. EF logs a warning when a query loads multiple collections and no splitting mode is configured.
  - Split queries with `Skip/Take` need a fully unique ordering. EF Core 10 fixed inconsistent ordering in split-query subqueries, so on older versions this is a real correctness bug.
- **Common pitfalls / red flags in answers:**
  - "Just add `Include` everywhere", which can turn N+1 into a cartesian explosion or over-fetching.
  - "Always use split queries". They hurt on high-latency links and give up single-statement consistency.
  - Not knowing how to *detect* N+1: logs that show N near-identical commands per request.
- **Example:**
  ```csharp
  // N+1: 1 query for blogs + 1 per blog (lazy-loading proxies on)
  foreach (var blog in await ctx.Blogs.ToListAsync())
      foreach (var post in blog.Posts) Console.WriteLine(post.Title);

  // Fix A: one query, only needed columns
  var data = await ctx.Blogs
      .Select(b => new { b.Url, Titles = b.Posts.Select(p => p.Title).ToList() })
      .ToListAsync();

  // Fix B: two sibling collections -> avoid cartesian explosion
  var blogs = await ctx.Blogs.AsNoTracking()
      .Include(b => b.Posts).Include(b => b.Contributors)
      .AsSplitQuery()
      .ToListAsync();
  ```
- **Sources:** [Efficient Querying: load related entities eagerly / avoid cartesian explosion](https://learn.microsoft.com/ef/core/performance/efficient-querying#load-related-entities-eagerly-when-possible), [Lazy Loading with proxies](https://learn.microsoft.com/ef/core/querying/related-data/lazy#lazy-loading-with-proxies), [Single vs. Split Queries](https://learn.microsoft.com/ef/core/querying/single-split-queries#performance-issues-with-single-queries), [Enabling split queries globally](https://learn.microsoft.com/ef/core/querying/single-split-queries#enabling-split-queries-globally), [What's New in EF Core 10: split query ordering](https://learn.microsoft.com/ef/core/what-is-new/ef-core-10.0/whatsnew#linq-and-sql-translation), [What's New in EF Core 8: lazy-loading enhancements](https://learn.microsoft.com/ef/core/what-is-new/ef-core-8.0/whatsnew#enhancements-to-lazy-loading)

### Database indexing for EF Core queries: defining indexes and reading query plans
- **What a Senior is expected to know:**
  - **Defining indexes in EF:** use `[Index(nameof(Url))]` or `HasIndex(b => b.Url)`. Composite: `HasIndex(p => new { p.LastName, p.FirstName })`. Also `IsUnique()`, `IsDescending(...)`, a filtered index via `HasFilter("[Url] IS NOT NULL")`, and SQL Server covering columns via `IncludeProperties(...)`. EF creates an index on foreign keys by convention. Indexes are applied through migrations.
  - **Composite index column order matters:** an index on (A, B) helps filters on A, and on A and B, but not on B alone. Column sort order should match the `ORDER BY` (key for keyset paging).
  - **Covering indexes:** if every column the query touches is in the index (key plus included columns), the table itself is not read. That is a strong reason to pair a projection with an index that has `INCLUDE` columns.
  - **Costs:** every index slows writes and uses storage. Add indexes for measured, frequent queries, and consider filtered indexes to reduce the overhead.
  - **Reading plans (SQL Server):** paste the logged SQL into SSMS, enable *Include Actual Execution Plan*, and look for scans versus seeks on large tables, the cost per operator, and estimated versus actual rows. Pair the plan with `SET STATISTICS IO ON` and compare `logical reads` before and after the index. Plans depend on data volume, so test with production-like data.
- **Common pitfalls / red flags in answers:**
  - "Index every column" or "add an index on each column separately" instead of one composite index matching the query.
  - Assuming the index is used without checking the plan (non-sargable predicates, `EndsWith`, `ToLower`, mismatched collation).
  - Judging an index by elapsed time on a warm cache instead of logical reads.
- **Example:**
  ```csharp
  modelBuilder.Entity<Order>()
      .HasIndex(o => new { o.CustomerId, o.CreatedAt })   // filter + ORDER BY
      .IsDescending(false, true)
      .IncludeProperties(o => new { o.Total, o.Status });  // covers the projection (SQL Server)
  ```
  ```sql
  SET STATISTICS IO ON;
  SELECT TOP(20) Total, Status, CreatedAt FROM Orders
  WHERE CustomerId = 42 ORDER BY CreatedAt DESC;
  -- Before: Clustered Index Scan, logical reads in the thousands
  -- After:  Index Seek on IX_Orders_CustomerId_CreatedAt, a handful of logical reads
  ```
  (The read counts are illustrative. Measure your own.)
- **Sources:** [Indexes (EF Core modeling)](https://learn.microsoft.com/ef/core/modeling/indexes), [Index filter and included columns](https://learn.microsoft.com/ef/core/modeling/indexes#index-filter), [Efficient Querying: use indexes properly](https://learn.microsoft.com/ef/core/performance/efficient-querying), [Performance Diagnosis: inspecting query execution plans](https://learn.microsoft.com/ef/core/performance/performance-diagnosis#inspecting-query-execution-plans), [Display an actual execution plan](https://learn.microsoft.com/sql/relational-databases/performance/display-an-actual-execution-plan?view=sql-server-ver17), [SET STATISTICS IO](https://learn.microsoft.com/sql/t-sql/statements/set-statistics-io-transact-sql?view=sql-server-ver17)

## Interview Questions

**EF Core performance: diagnosing and fixing slow data access**
1. *An endpoint got slow in production. How do you find out whether EF is the cause?* Strong answer covers: enabling command logging briefly or in pre-production, checking per-command durations *and* command counts, `TagWith` to map SQL to code, then the execution plan, all before changing code.
2. *Why shouldn't you leave EF command logging at Information level in production?* Strong answer covers: overhead and log volume. Use short windows, sampling, or pre-production capture instead.
3. *A query is fast locally and slow in production. Why?* Strong answer covers: data volume changes the plan (scan versus seek), network latency multiplies round trips, and unbounded result sets.
4. *When would you consider leaving LINQ for raw SQL?* Strong answer covers: only after measuring and after LINQ-level fixes (projection, indexes, split queries) have been tried.

**EF Core query optimization: projections, filtering, pagination, and inspecting generated SQL**
1. *What's wrong with `ctx.Posts.ToList().Where(p => p.Title.Contains(x))`?* Strong answer covers: it loads the whole table into memory and filters on the client. Keep the query as `IQueryable` until the end.
2. *Offset versus keyset pagination: trade-offs?* Strong answer covers: OFFSET cost grows with the page number and pages drift under concurrent writes. Keyset is cheap with an index but has no random page access. Ordering must be unique.
3. *How do you see the SQL EF will run without executing it?* Strong answer covers: `ToQueryString()`. For executed SQL and timings, use logging.
4. *Why might `Where(p => p.Email.ToLower() == x)` be slow?* Strong answer covers: a function on the column is not sargable and blocks index use. Use the right collation on the column instead.

**AsNoTracking and change tracking costs in EF Core**
1. *When would you use AsNoTracking, and when not?* Strong answer covers: read-only paths yes. Not for entities you will modify. Mention the context-wide default and `AsTracking`.
2. *Can a no-tracking query be slower or behave differently?* Strong answer covers: no identity resolution gives duplicate instances; `AsNoTrackingWithIdentityResolution` fixes that. Tracking can reuse instances that are already tracked.
3. *Is a `Select` into a DTO tracked?* Strong answer covers: no, unless the projection contains entity instances.
4. *What is DetectChanges, and when would you disable it?* Strong answer covers: snapshot comparison on `SaveChanges`/`Entries`. Disable it only when profiling shows a cost with thousands of tracked entities, and restore it in a `finally`.

**N+1 queries in EF Core: lazy loading, Include, and split queries**
1. *Explain N+1 and how you'd spot it.* Strong answer covers: per-parent navigation access in a loop. Logs show N similar commands. Lazy loading hides it.
2. *Include versus projection for related data?* Strong answer covers: Include loads full entities (tracked by default). A projection loads only the needed columns in one query and is better for read models.
3. *What is cartesian explosion, and how do split queries help? What do they cost?* Strong answer covers: sibling collection JOINs multiply rows. A split query runs one query per collection. Costs: extra round trips, no cross-query consistency without a transaction, buffering.
4. *Would you enable lazy loading in an ASP.NET Core API?* Strong answer covers: generally no. It causes hidden round trips and synchronous I/O. Prefer explicit eager loading or projections.

**Database indexing for EF Core queries: defining indexes and reading query plans**
1. *You have an index on (LastName, FirstName). Which queries benefit?* Strong answer covers: filters on LastName, or on both. Not FirstName alone.
2. *What is a covering index, and how do you define one in EF Core?* Strong answer covers: all the query's columns are in the index, so the table is not read. `HasIndex(...).IncludeProperties(...)` on SQL Server.
3. *How do you prove an index helped?* Strong answer covers: actual execution plan (seek versus scan, estimated versus actual rows) plus `SET STATISTICS IO` logical reads, before and after, on realistic data.
4. *Why not index every column?* Strong answer covers: write overhead and storage. Use filtered indexes for subsets, and index measured hot queries only.

## Hands-on Exercises

All exercises share one console app: EF Core 10 with SQL Server LocalDB or Docker, a `Blog`/`Post`/`Contributor` model, and a seed of about 1,000 blogs with about 50 posts each, so that plans and timings mean something. Set up `LogTo(Console.WriteLine, LogLevel.Information)` once.

**EF Core performance: diagnosing and fixing slow data access** (about 20 minutes)
- Goal: diagnose a deliberately slow request from logs alone.
- Steps: write a method `GetDashboard()` that runs 3 or 4 queries (one N+1 loop, one unbounded `ToList`). Tag each with `TagWithCallSite()`. Run it and read the log.
- Observe: the number of `Executed DbCommand` lines, the slowest duration, and which source line each one came from. Write down your top 2 suspects before fixing anything.

**EF Core query optimization: projections, filtering, pagination, and inspecting generated SQL** (about 25 minutes)
- Goal: measure projection and keyset paging against the naive version.
- Steps: (1) compare `ctx.Posts.ToListAsync()` with `Select(p => new { p.PostId, p.Title })`, and print `ToQueryString()` for both. (2) Fetch page 2,000 with `Skip/Take`, then with keyset `Where(PostId > lastId)`. Time both with `Stopwatch` and run them under `SET STATISTICS IO ON` in SSMS.
- Observe: the column list in the SQL, the logical reads, and how elapsed time grows with the page number for offset paging but stays flat for keyset paging.

**AsNoTracking and change tracking costs in EF Core** (about 15 minutes)
- Goal: see the tracking cost and the identity-resolution difference.
- Steps: load 50,000 posts with and without `AsNoTracking()`. Record time and `GC.GetTotalAllocatedBytes()`, and check `ctx.ChangeTracker.Entries().Count()`. Then `Include(p => p.Blog)` with `AsNoTracking` and check whether two posts of the same blog share a `Blog` instance (`ReferenceEquals`). Repeat with `AsNoTrackingWithIdentityResolution()`.
- Observe: the tracked-entry count, time and allocations, and the duplicate versus shared instances.

**N+1 queries in EF Core: lazy loading, Include, and split queries** (about 25 minutes)
- Goal: reproduce N+1 and cartesian explosion, then fix them.
- Steps: enable `UseLazyLoadingProxies()` and loop over blogs → posts, counting the logged commands. Fix it with a projection, then with `Include`. Next, `Include` both `Posts` and `Contributors`, and note the row count and the logged multiple-collection warning. Add `AsSplitQuery()` and compare.
- Observe: commands per run (N+1 versus 1 versus 2 or 3), rows returned by the single JOIN versus the split queries, and total time.

**Database indexing for EF Core queries: defining indexes and reading query plans** (about 25 minutes)
- Goal: prove an index with a plan and logical reads.
- Steps: take the logged SQL for `Posts.Where(p => p.BlogId == x && p.PublishedOn > d).OrderBy(p => p.PublishedOn).Select(p => new { p.Title, p.PublishedOn })`. Run it in SSMS with *Include Actual Execution Plan* and `SET STATISTICS IO ON`. Add `HasIndex(p => new { p.BlogId, p.PublishedOn }).IncludeProperties(p => p.Title)` through a migration and rerun. As a bonus, change the filter to `Title.EndsWith(...)` and watch the index stop being used.
- Observe: the scan-to-seek change, the drop in logical reads, and estimated versus actual rows.

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
- Collations and Case Sensitivity: explicit collation and indexes: https://learn.microsoft.com/ef/core/miscellaneous/collations-and-case-sensitivity#explicit-collation-in-a-query
- Tracking vs. No-Tracking Queries: https://learn.microsoft.com/ef/core/querying/tracking
- Identity Resolution in EF Core: https://learn.microsoft.com/ef/core/change-tracking/identity-resolution#identity-resolution-and-queries
- Change Detection and Notifications: https://learn.microsoft.com/ef/core/change-tracking/change-detection#snapshot-change-tracking
- Lazy Loading of Related Data: https://learn.microsoft.com/ef/core/querying/related-data/lazy#lazy-loading-with-proxies
- Single vs. Split Queries: https://learn.microsoft.com/ef/core/querying/single-split-queries#performance-issues-with-single-queries
- Single vs. Split Queries: enabling globally / multiple-collection warning: https://learn.microsoft.com/ef/core/querying/single-split-queries#enabling-split-queries-globally
- What's New in EF Core 10: split query ordering: https://learn.microsoft.com/ef/core/what-is-new/ef-core-10.0/whatsnew#linq-and-sql-translation
- What's New in EF Core 8: lazy-loading enhancements: https://learn.microsoft.com/ef/core/what-is-new/ef-core-8.0/whatsnew#enhancements-to-lazy-loading
- Indexes (EF Core modeling): https://learn.microsoft.com/ef/core/modeling/indexes
- Indexes: index filter and included columns: https://learn.microsoft.com/ef/core/modeling/indexes#index-filter
- Display an actual execution plan (SQL Server): https://learn.microsoft.com/sql/relational-databases/performance/display-an-actual-execution-plan?view=sql-server-ver17
- SET STATISTICS IO (Transact-SQL): https://learn.microsoft.com/sql/t-sql/statements/set-statistics-io-transact-sql?view=sql-server-ver17

## Gaps and Limitations
- All sources are Microsoft Learn, retrieved through `microsoft_docs_search`. Full pages were not fetched with `microsoft_docs_fetch`; claims rest on the excerpts the search returned. `WebSearch`/`WebFetch` were not used, so there are no non-Microsoft expert sources (for example, blog posts on N+1 detection tooling). No tool failures occurred.
- Version: the docs already include an "EF Core 11" what's-new page. I did not verify whether EF Core 11 has shipped as of 2026-10-12, so I assumed EF Core 10 / .NET 10 as the current LTS, per the requirements assumption. SQL Server docs were retrieved at `view=sql-server-ver17`. The advice applies to SQL Server 2022 and later.
- Plan-operator names beyond "scan" and "seek", and the logical-read numbers in the indexing example, are illustrative and were not taken from a source. The exercises are designed to have the learner measure real values.
- The Tracking vs. No-Tracking page says a later section explains when no-tracking can be less efficient. I saw only the excerpt saying tracking queries "can potentially use less memory and be faster" when they reuse instances that are already tracked. The finding states only that.
- Provider-specific: `IncludeProperties`, the filter syntax `[Url] IS NOT NULL`, SSMS plans, and `SET STATISTICS IO` are SQL Server-specific. Other providers (for example PostgreSQL `EXPLAIN ANALYZE`) were not researched.
- The level conflict (the agent brief says Senior, the requirements say Middle+) was resolved toward Middle+ with upper-end questions.
