---
artifact: plan
run_id: 20261013-134101-resume-demo-async-ad8d3d
generated_by: study-planner
budget_hours: 3
planned_hours: 3
research_inputs:
  - research/dotnet.md
---

# Study Plan: Middle .NET Backend, async/await in C#, 6 sessions in 10 days

## Summary
This plan prepares a Middle-level .NET backend candidate for an interview in about 10 days, focused entirely on the one stated gap: async/await in C#. It uses the full 3-hour budget as 6 sessions of 30 minutes (Day 1 to Day 6). Five sessions are hands-on and use the four exercises from research. Each pairs a short theory block with the code, and most end with short interview questions. The sixth session is spaced revision plus a mock interview. Every session uses a backend lens (ASP.NET Core endpoints, thread-pool starvation, cancellation flowed from the request), as the role requires.

## Assumptions
Repeated from *Open Questions and Assumptions* in `requirements.md`:
- **Interview date:** about 10 days after the requirements were confirmed (on or around 2026-10-23). All 6 sessions must be finished before it.
- **Study days:** which 6 of the 10 days was not specified. The plan schedules Day 1 to Day 6 and works on any 6 days before the interview. Weeks 1 and 2 in the schedule only spread the 6 days over the 10-day window. Spacing sessions out (for example, one rest day before Day 6) helps revision.
- **Strengths:** none were named. No other topic gets dedicated time, and no strength is assumed.
- **Mandatory topics:** only the stated gap, async/await in C#.
- **Backend lens:** applying async/await in a .NET backend is optional and covered inside the async/await sessions, not as a separate topic.
- **Depth over breadth:** the plan goes deep on async/await in C#.
- **Constraints:** free, public resources and a local .NET SDK for the exercises.
- **.NET version:** latest LTS. Research assumed .NET 10 (LTS) and ASP.NET Core 10, so the exercises use a local .NET 10 SDK.
- **Interview format:** a generic technical interview for a Middle .NET backend role, with conceptual questions and possibly code reading or writing.
- **Language:** English materials.
- **Time budget:** 3 hours, as stated (30 minutes x 6 days = 180 minutes). No session exceeds 30 minutes.

Research gaps that affect the plan:
- **EF Core `DbContext` concurrency.** The note that one scoped `DbContext` must not run concurrent operations has no source in research. The plan presents it as general guidance only, with no citation, and does not build an exercise on it.
- **`ValueTask<T>`.** The guidance (stretch question 8) has no Microsoft Learn source in research. It stays an optional stretch question and is not part of the mock interview.
- **`dotnet-counters`.** The counter names used in Exercise 2 were not verified. Watching them is optional; the latency comparison is the required observation.
- **Revision share.** Because sessions are fixed at 30 minutes, the dedicated revision and mock session is 30 of 180 minutes (about 17%), slightly above the 10–15% target. Short recaps at the start of sessions 3 to 5 are part of those sessions, not extra time.

## Time Budget
- **Budget:** 3 hours (180 minutes). **Planned:** 3 hours (180 minutes), in 6 sessions of 30 minutes.
- **async/await in C# (theory, practice, interview):** 150 minutes (sessions 1 to 5). Roughly 35 minutes of theory, 90 minutes of hands-on exercises, and 25 minutes of interview questions, spread across the sessions.
- **Revision and mock interview:** 30 minutes (session 6): 10 minutes of revision, 20 minutes of mock interview.
- **Other topics:** 0 minutes, because the user's only stated weak area is async/await in C#.

## Schedule
| # | Week | Topic | Activities | Minutes | Sources |
|---|---|---|---|---|---|
| 1 | 1 | async/await in C# | theory, practice | 30 | https://learn.microsoft.com/dotnet/csharp/asynchronous-programming/ ; https://learn.microsoft.com/dotnet/csharp/asynchronous-programming/task-asynchronous-programming-model#threads |
| 2 | 1 | async/await in C# | theory, practice | 30 | https://learn.microsoft.com/aspnet/core/fundamentals/best-practices?view=aspnetcore-10.0#avoid-blocking-calls ; https://learn.microsoft.com/dotnet/csharp/asynchronous-programming/async-scenarios#explore-the-asynchronous-programming-model |
| 3 | 1 | async/await in C# | practice, interview | 30 | https://learn.microsoft.com/aspnet/core/fundamentals/best-practices?view=aspnetcore-10.0#avoid-blocking-calls ; https://learn.microsoft.com/dotnet/standard/asynchronous-programming-patterns/common-async-bugs#deadlocks-from-blocking-on-async-code |
| 4 | 2 | async/await in C# | theory, practice, interview | 30 | https://learn.microsoft.com/aspnet/core/fundamentals/best-practices?view=aspnetcore-10.0#do-not-use-the-httpcontext-after-the-request-is-complete ; https://github.com/davidfowl/AspNetCoreDiagnosticScenarios/blob/master/AsyncGuidance.md |
| 5 | 2 | async/await in C# | theory, practice, interview | 30 | https://learn.microsoft.com/dotnet/standard/asynchronous-programming-patterns/consuming-the-task-based-asynchronous-pattern#using-the-built-in-task-based-combinators ; https://learn.microsoft.com/dotnet/standard/parallel-programming/task-cancellation |
| 6 | 2 | Revision and mock interview | revision, mock | 30 | https://devblogs.microsoft.com/dotnet/configureawait-faq/ ; https://learn.microsoft.com/dotnet/standard/asynchronous-programming-patterns/common-async-bugs#deadlocks-from-blocking-on-async-code |

Session details:
1. **Day 1. How `await` works (Exercise 1).** 10 min theory: the compiler-generated state machine, continuations, and why async/await creates no threads. 20 min: Exercise 1 (thread IDs around `await Task.Delay(500)`, the "async without await" warning, sequential vs. `Task.WhenAll` timing).
2. **Day 2. Why blocking hurts a backend (Exercise 2, part 1).** 10 min theory: I/O-bound vs. CPU-bound work, "async all the way", thread-pool starvation. 20 min: create the `dotnet new web` app with `/sync` and `/async` endpoints, and the small `HttpClient` load loop.
3. **Day 3. Measure starvation (Exercise 2, part 2).** 3 min recap of Day 1. 17 min: run about 200 concurrent requests against each endpoint and compare latency (optionally watch `dotnet-counters`). 10 min: interview questions 2 and 3, answered out loud.
4. **Day 4. Fix-the-bugs code review (Exercise 3).** 5 min theory: `async void` in ASP.NET Core, `Task.Run` misuse, flowing `CancellationToken`. 20 min: Exercise 3 (four planted bugs). 5 min: interview questions 4 and 5.
5. **Day 5. Exceptions and cancellation (Exercise 4).** 3 min recap of Days 2 to 4. 7 min theory: `Task.WhenAll` and `AggregateException`, `Canceled` vs. `Faulted`, `ConfigureAwait(false)`. 15 min: Exercise 4. 5 min: interview questions 6 and 7.
6. **Day 6. Revision and mock interview.** 10 min revision, 20 min mock interview (see *Revision and Mock Interviews*).

## Topic Plans

### async/await in C#
- **Why it matters for this role:** In a .NET backend, async APIs let a small thread pool serve thousands of concurrent requests. Blocking calls such as `.Result` or `.Wait()` cause thread-pool starvation and slow responses. Interviewers for a Middle backend role expect you to explain how `await` works and to spot common async bugs in code review.
- **Theory:**
  - **Mechanics.** The compiler turns an `async` method into a state machine. At an `await` on an incomplete task, the rest of the method is registered as a continuation and control returns to the caller. `async`/`await` do not create threads. A method marked `async` with no `await` runs synchronously, and the compiler warns. Sources: [Asynchronous programming with async and await](https://learn.microsoft.com/dotnet/csharp/asynchronous-programming/), [Task asynchronous programming model: Threads](https://learn.microsoft.com/dotnet/csharp/asynchronous-programming/task-asynchronous-programming-model#threads).
  - **I/O-bound vs. CPU-bound.** Await async I/O APIs directly, without `Task.Run`. In ASP.NET Core, do not call `Task.Run` and immediately await it: request code already runs on thread-pool threads. Source: [Asynchronous programming scenarios](https://learn.microsoft.com/dotnet/csharp/asynchronous-programming/async-scenarios#explore-the-asynchronous-programming-model).
  - **Backend impact.** Blocking calls (`.Result`, `.Wait()`, synchronous reads of `Request.Body`) starve the thread pool. Make the whole call stack async, from the endpoint down to data access and `HttpClient`. Source: [ASP.NET Core Best Practices: Avoid blocking calls](https://learn.microsoft.com/aspnet/core/fundamentals/best-practices?view=aspnetcore-10.0#avoid-blocking-calls).
  - **Return types.** Use `Task` or `Task<T>`. `async void` is only for event handlers; in ASP.NET Core the request completes at the first `await`, and later access to `HttpContext` can crash the process. Sources: [ASP.NET Core Best Practices: HttpContext after the request](https://learn.microsoft.com/aspnet/core/fundamentals/best-practices?view=aspnetcore-10.0#do-not-use-the-httpcontext-after-the-request-is-complete), [AsyncGuidance](https://github.com/davidfowl/AspNetCoreDiagnosticScenarios/blob/master/AsyncGuidance.md).
  - **Composition, exceptions, cancellation.** Start independent work first, then `await Task.WhenAll(...)`. All exceptions are stored in an `AggregateException`, but `await` rethrows only one; inspect each task to see them all. Pass a `CancellationToken` (for example `HttpContext.RequestAborted` or an action parameter) to every API that accepts one. A cancelled task ends `Canceled`, not `Faulted`. Sources: [Consuming the TAP: combinators](https://learn.microsoft.com/dotnet/standard/asynchronous-programming-patterns/consuming-the-task-based-asynchronous-pattern#using-the-built-in-task-based-combinators), [Task cancellation](https://learn.microsoft.com/dotnet/standard/parallel-programming/task-cancellation).
  - **`ConfigureAwait(false)` and deadlocks.** The classic deadlock comes from blocking on async work on a thread with a single-threaded `SynchronizationContext` (UI, classic ASP.NET). ASP.NET Core has no `SynchronizationContext`, so app code does not need `ConfigureAwait(false)`; general-purpose libraries should still use it. Blocking is still harmful in ASP.NET Core because it starves the pool. Sources: [Common async/await bugs](https://learn.microsoft.com/dotnet/standard/asynchronous-programming-patterns/common-async-bugs#deadlocks-from-blocking-on-async-code), [ConfigureAwait FAQ](https://devblogs.microsoft.com/dotnet/configureawait-faq/).
  - **Backend example to study.** The research's before-and-after `/orders/{id}` controller: the "bad" version blocks three times with `.Result`; the "good" version is `async Task<ActionResult<OrderDto>>`, awaits the order first, then runs the customer lookup and the shipping HTTP call concurrently with `Task.WhenAll`, and flows `CancellationToken ct`. General guidance (not sourced in research): do not run concurrent queries on one shared scoped EF Core `DbContext`; parallelize only independent resources, such as a database query and an HTTP call.
  - **Red flags to avoid in answers:** "`async` runs the method on a background thread"; "`await` creates a thread"; using `.Result`, `.Wait()`, or `GetAwaiter().GetResult()` "to keep it simple"; wrapping sync calls in `Task.Run` to "make them async"; `async void` actions; awaiting independent calls one after another.
- **Practice:** (all exercises from research; local .NET 10 SDK)
  1. **Exercise 1: Watch the state machine (Day 1, 20 min).** In an `async Task Main`, log `Environment.CurrentManagedThreadId` before and after `await Task.Delay(500)`. Add an `async` method with no `await` and read the warning. Time three `Task.Delay(1000)` calls sequentially and with `Task.WhenAll`, using `Stopwatch`.
     - *Observe:* the thread ID can change after the `await`; sequential takes about 3 s, `WhenAll` about 1 s; the warning shows that a method without `await` runs synchronously.
  2. **Exercise 2: Thread-pool starvation in a minimal API (Days 2 and 3, 37 min).** Create `dotnet new web` with `/sync` (`Task.Delay(500).Wait(); return "ok";`) and `/async` (`await Task.Delay(500); return "ok";`). Load each with about 200 concurrent requests from a small `HttpClient` console loop using `Task.WhenAll`. Optionally run `dotnet-counters monitor -n <app> System.Runtime` (counter names unverified).
     - *Measure:* latency per endpoint. `/sync` latency climbs and the thread count grows slowly; `/async` stays near 500 ms with few threads.
  3. **Exercise 3: Fix-the-bugs code review (Day 4, 20 min).** Write a controller with four planted bugs: an `async void` action, `.Result` on a repository call, `await Task.Run(() => _repo.GetAsync())`, and three independent awaits run sequentially. Fix each one, add `CancellationToken ct`, and pass it down.
     - *Observe:* explain each fix out loud in one sentence. That sentence is your interview answer.
  4. **Exercise 4: Cancellation and WhenAll exceptions (Day 5, 15 min).** Run `Task.WhenAll` over two tasks that throw different exceptions; print `ex.GetType()` and then each task's `Exception`. Use `new CancellationTokenSource(TimeSpan.FromMilliseconds(200))` with `Task.Delay(1000, cts.Token)` and print `task.Status`.
     - *Observe:* `await` surfaces one exception while the tasks hold all of them; the cancelled task's status is `Canceled`, with `Exception == null`.
- **Interview questions:** (short answers, out loud, at most 1 to 2 minutes each)
  1. *What actually happens when execution reaches `await` on a task that has not completed?*
     - Strong answer covers: the compiler-generated state machine; the rest of the method registered as a continuation; control returns to the caller; resumption when the task completes; no thread created or blocked while waiting.
  2. *Why does async/await improve the scalability of an ASP.NET Core API but not the speed of a single request?*
     - Strong answer covers: threads freed during I/O waits so a small pool serves many requests; blocking leads to thread-pool starvation; async adds a small per-call overhead.
  3. *A colleague writes `var user = _repo.GetUserAsync(id).Result;` in a controller. What is wrong, and would it deadlock in ASP.NET Core?*
     - Strong answer covers: sync-over-async blocks a pool thread and risks starvation under load; usually no deadlock in ASP.NET Core (no `SynchronizationContext`), but it can deadlock in UI apps or classic ASP.NET; fix by awaiting and making the action `async Task<...>`.
  4. *When would you use `Task.Run` in a web API, and when should you not?*
     - Strong answer covers: not for I/O, not to "async-ify" a synchronous API, not as `await Task.Run(...)` in request code; long CPU-bound work belongs in a background service or queue.
  5. *Why is `async void` dangerous in ASP.NET Core, and where is it acceptable?*
     - Strong answer covers: the caller cannot await or observe it; exceptions can crash the process; the request may complete before the work does; acceptable only for event handlers.
  6. *You call three independent services. How do you run them concurrently, and how do you handle a failure?*
     - Strong answer covers: start the tasks, then `await Task.WhenAll`; `await` rethrows only the first exception, so inspect each task's `Exception`; flow a `CancellationToken`.
  7. *Do you need `ConfigureAwait(false)` in an ASP.NET Core controller? In a NuGet library?*
     - Strong answer covers: no in app code (no `SynchronizationContext`); yes in general-purpose libraries, to avoid deadlocks and needless context switches.
  8. *(Stretch, optional) When would you return `ValueTask<T>` instead of `Task<T>`?*
     - Strong answer covers: hot paths that often complete synchronously, such as cache hits, to avoid an allocation; a `ValueTask` must be awaited only once. (No Microsoft Learn source in research; see *Assumptions*.)
- **Sources:**
  - https://learn.microsoft.com/dotnet/csharp/asynchronous-programming/
  - https://learn.microsoft.com/dotnet/csharp/asynchronous-programming/task-asynchronous-programming-model#threads
  - https://learn.microsoft.com/dotnet/csharp/asynchronous-programming/async-scenarios#explore-the-asynchronous-programming-model
  - https://learn.microsoft.com/aspnet/core/fundamentals/best-practices?view=aspnetcore-10.0#avoid-blocking-calls
  - https://learn.microsoft.com/aspnet/core/fundamentals/best-practices?view=aspnetcore-10.0#do-not-use-the-httpcontext-after-the-request-is-complete
  - https://learn.microsoft.com/dotnet/standard/asynchronous-programming-patterns/common-async-bugs#deadlocks-from-blocking-on-async-code
  - https://learn.microsoft.com/dotnet/standard/asynchronous-programming-patterns/consuming-the-task-based-asynchronous-pattern#using-the-built-in-task-based-combinators
  - https://learn.microsoft.com/dotnet/standard/parallel-programming/task-cancellation
  - https://devblogs.microsoft.com/dotnet/configureawait-faq/
  - https://github.com/davidfowl/AspNetCoreDiagnosticScenarios/blob/master/AsyncGuidance.md

## Revision and Mock Interviews
Spaced revision:
- **Day 3 (3 min, inside session 3):** without notes, explain what happens at `await` and why no thread is created (Day 1 material).
- **Day 5 (3 min, inside session 5):** list the four bugs from Exercise 3 and the one-sentence fix for each, and state the `/sync` vs. `/async` result from Exercise 2.
- **Day 6 (10 min, session 6):** re-read the red-flag list and the before-and-after `/orders/{id}` controller from the topic plan. Then rewrite the "bad" version from memory as the "good" version, including `CancellationToken` and `Task.WhenAll`.

Mock interview (Day 6, 20 min). Ideally ask someone to play the interviewer; otherwise record yourself. Answer each question in at most 2 minutes, then compare with the "strong answer covers" notes and mark any missed point:
1. Question 1: what happens at `await` on an incomplete task.
2. Question 3: `.Result` in a controller, and whether it deadlocks in ASP.NET Core.
3. Question 6: three independent services, concurrency, and failure handling.
4. Question 5: `async void` in ASP.NET Core.
5. Question 7: `ConfigureAwait(false)` in app code vs. a library.
6. Code reading: show the "bad" `/orders/{id}` controller and ask the candidate to find the problems and rewrite it (expected: async all the way, `Task.WhenAll` for independent I/O, flowed `CancellationToken`).

Revisit any question you marked as missed once more on a day before the interview, within the existing sessions; no extra time is scheduled.

## Sources
- Asynchronous programming with async and await (Microsoft Learn): https://learn.microsoft.com/dotnet/csharp/asynchronous-programming/
- Task asynchronous programming model, Threads (Microsoft Learn): https://learn.microsoft.com/dotnet/csharp/asynchronous-programming/task-asynchronous-programming-model#threads
- Asynchronous programming scenarios (Microsoft Learn): https://learn.microsoft.com/dotnet/csharp/asynchronous-programming/async-scenarios#explore-the-asynchronous-programming-model
- ASP.NET Core Best Practices, Avoid blocking calls (Microsoft Learn): https://learn.microsoft.com/aspnet/core/fundamentals/best-practices?view=aspnetcore-10.0#avoid-blocking-calls
- ASP.NET Core Best Practices, Do not use the HttpContext after the request is complete (Microsoft Learn): https://learn.microsoft.com/aspnet/core/fundamentals/best-practices?view=aspnetcore-10.0#do-not-use-the-httpcontext-after-the-request-is-complete
- Common async/await bugs (Microsoft Learn): https://learn.microsoft.com/dotnet/standard/asynchronous-programming-patterns/common-async-bugs#deadlocks-from-blocking-on-async-code
- Consuming the Task-based Asynchronous Pattern (Microsoft Learn): https://learn.microsoft.com/dotnet/standard/asynchronous-programming-patterns/consuming-the-task-based-asynchronous-pattern#using-the-built-in-task-based-combinators
- Task cancellation (Microsoft Learn): https://learn.microsoft.com/dotnet/standard/parallel-programming/task-cancellation
- ConfigureAwait FAQ (.NET Blog): https://devblogs.microsoft.com/dotnet/configureawait-faq/
- AsyncGuidance, ASP.NET Core Diagnostic Scenarios (David Fowler, GitHub): https://github.com/davidfowl/AspNetCoreDiagnosticScenarios/blob/master/AsyncGuidance.md

## Optional Extensions
No budget remains, so nothing here is scheduled.
- **Stretch question 8 (`ValueTask<T>`):** practice it only if time is left after the mock interview. Research has no Microsoft Learn source for it.
- **`dotnet-counters` observation in Exercise 2:** an optional aid; the counter names were not verified in research.
- **EF Core `DbContext` and concurrency:** worth confirming in the EF Core documentation before relying on it in an interview. Research did not source it, so no link is given here.
- **Topics left out on purpose** (beyond a Middle async/await interview and the 3-hour budget, per research): TPL Dataflow, Channels, `Parallel.ForEach` and PLINQ, custom awaiters, `IValueTaskSource`, thread-pool tuning, and lock-free concurrency.
