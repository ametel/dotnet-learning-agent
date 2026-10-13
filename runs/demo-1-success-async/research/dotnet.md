---
artifact: research
area: dotnet
run_id: 20261013-134101-resume-demo-async-ad8d3d
generated_by: dotnet-researcher
assumed_dotnet_version: .NET 10 (LTS)
---

# Research: .NET Runtime, C#, Async and Concurrency

## Scope
- **Assigned topic:** async/await in C#: how it works and how to use it correctly in .NET backend code. It covers the mandatory topic "async/await in C#" and the derived backend lens (requirements, assumption 5).
- **Level:** **Middle** .NET backend, per `requirements.md`. The agent template defaults to Senior, but the requirements take precedence. Content is pitched at a Middle candidate who should answer confidently and spot common bugs in code reviews. A few "stretch" points are marked for extra credit.
- **Budget fit:** 3 hours in total (6 × 30 min). Each exercise below fits in one 30-minute session.
- **Assumed:** .NET 10 (LTS) and ASP.NET Core 10, with a local .NET SDK and free resources only (requirements, assumptions 7 and 8).
- **Deliberately left out:** TPL Dataflow, Channels, `Parallel.ForEach` and PLINQ, custom awaiters, `IValueTaskSource`, deep thread-pool tuning, and lock-free concurrency. These are beyond a Middle async/await interview and the 3-hour budget.

## Findings

### async/await in C#: how it works and how to use it correctly in .NET backend code
- **What a Middle backend candidate is expected to know:**
  - **How the mechanics work.** The compiler turns an `async` method into a state machine. At each `await` on an incomplete task, the rest of the method is registered as a continuation and control returns to the caller. `async`/`await` do **not** create threads, and an async method does not run on its own thread. If a method is marked `async` but has no `await`, it runs synchronously and the compiler warns.
  - **I/O-bound vs. CPU-bound work.** For I/O (database, HTTP, files), await the async API directly, without `Task.Run`. For CPU-bound work, `Task.Run` offloads to the thread pool, but in ASP.NET Core you should **not** call `Task.Run` and immediately await it. Request code already runs on thread-pool threads, so this only adds scheduling overhead.
  - **Why it matters in a backend.** Async APIs let a small thread pool serve thousands of concurrent requests. Blocking calls (`.Result`, `.Wait()`, synchronous I/O such as `StreamReader.ReadToEnd` on `Request.Body`) cause **thread-pool starvation** and slow responses. Make the whole call stack async ("async all the way"), from the controller or endpoint down to EF Core and `HttpClient`.
  - **Return types and rules.** Use `Task` or `Task<T>`, and `ValueTask<T>` for hot paths that often complete synchronously. `async void` is only for event handlers. In ASP.NET Core it is always a bad practice: the request completes at the first `await`, and later access to `HttpContext` or the response can crash the process.
  - **Composition, exceptions, cancellation.** Start independent work first, then `await Task.WhenAll(...)`. If tasks fault, `WhenAll` stores all exceptions in an `AggregateException`, but `await` rethrows only one. Inspect each task to see them all. Pass a `CancellationToken` (for example `HttpContext.RequestAborted`, or a token action parameter) to every API that accepts one. A cancelled task ends in the `Canceled` state, which is not `Faulted`.
  - **`ConfigureAwait(false)` and deadlocks.** The classic deadlock happens when code blocks on async work on a thread with a single-threaded `SynchronizationContext` (UI, or classic ASP.NET on .NET Framework). **ASP.NET Core has no `SynchronizationContext`**, so app code there does not need `ConfigureAwait(false)`. General-purpose library code should still use it. Blocking is still harmful in ASP.NET Core because it starves the thread pool.
- **Common pitfalls / red flags in answers:**
  - Saying "`async` makes the method run on a background thread" or "`await` creates a new thread."
  - Using `.Result`, `.Wait()`, or `GetAwaiter().GetResult()` in request code "to keep it simple," or wrapping synchronous calls in `Task.Run` to "make them async."
  - Using `async void` controller actions or fire-and-forget work that touches `HttpContext` or a scoped `DbContext` after the request ends.
  - Awaiting independent calls one after another when they could run concurrently. Conversely, running concurrent operations on one EF Core `DbContext`, which is not thread-safe. That last point comes from general EF Core knowledge and was not verified in this session; see *Gaps*.
- **Example (backend, before and after):**
  ```csharp
  // BAD: sync-over-async and sequential calls. Blocks a pool thread for the whole I/O.
  [HttpGet("/orders/{id}")]
  public ActionResult<OrderDto> Get(int id)
  {
      var order    = _orders.GetAsync(id).Result;          // blocks: risk of starvation
      var customer = _customers.GetAsync(order.CustomerId).Result;
      var shipping = _shippingClient.GetStatusAsync(id).Result;
      return new OrderDto(order, customer, shipping);
  }

  // GOOD: async all the way, independent I/O in parallel, cancellation flowed.
  [HttpGet("/orders/{id}")]
  public async Task<ActionResult<OrderDto>> Get(int id, CancellationToken ct)
  {
      var order = await _orders.GetAsync(id, ct);              // needed before customer lookup
      var customerTask = _customers.GetAsync(order.CustomerId, ct);
      var shippingTask = _shippingClient.GetStatusAsync(id, ct); // independent HTTP call
      await Task.WhenAll(customerTask, shippingTask);
      return new OrderDto(order, await customerTask, await shippingTask);
  }
  ```
  If `_customers` and `_orders` share one scoped EF Core `DbContext`, do **not** run their queries concurrently. Only the HTTP call and the database query are parallelized here.
- **Sources:** [Asynchronous programming with async and await](https://learn.microsoft.com/dotnet/csharp/asynchronous-programming/), [Task asynchronous programming model: Threads](https://learn.microsoft.com/dotnet/csharp/asynchronous-programming/task-asynchronous-programming-model#threads), [Asynchronous programming scenarios](https://learn.microsoft.com/dotnet/csharp/asynchronous-programming/async-scenarios#explore-the-asynchronous-programming-model), [ASP.NET Core Best Practices: Avoid blocking calls](https://learn.microsoft.com/aspnet/core/fundamentals/best-practices?view=aspnetcore-10.0#avoid-blocking-calls), [ASP.NET Core Best Practices: async void / HttpContext](https://learn.microsoft.com/aspnet/core/fundamentals/best-practices?view=aspnetcore-10.0#do-not-use-the-httpcontext-after-the-request-is-complete), [Common async/await bugs](https://learn.microsoft.com/dotnet/standard/asynchronous-programming-patterns/common-async-bugs#deadlocks-from-blocking-on-async-code), [Consuming the TAP: combinators](https://learn.microsoft.com/dotnet/standard/asynchronous-programming-patterns/consuming-the-task-based-asynchronous-pattern#using-the-built-in-task-based-combinators), [Task cancellation](https://learn.microsoft.com/dotnet/standard/parallel-programming/task-cancellation), [ConfigureAwait FAQ](https://devblogs.microsoft.com/dotnet/configureawait-faq/), [AsyncGuidance (David Fowler)](https://github.com/davidfowl/AspNetCoreDiagnosticScenarios/blob/master/AsyncGuidance.md)

## Interview Questions

**async/await in C#: how it works and how to use it correctly in .NET backend code**

1. *What actually happens when execution reaches `await` on a task that has not completed?*
   A strong answer covers the compiler-generated state machine, how the rest of the method is registered as a continuation, how control returns to the caller, and how the method resumes when the task completes. No thread is created or blocked while it waits.
2. *Why does async/await improve the scalability of an ASP.NET Core API but not the speed of a single request?*
   A strong answer covers how threads are freed during I/O waits so a small pool can serve many concurrent requests, how blocking leads to thread-pool starvation, and that async adds a small overhead to each call.
3. *A colleague writes `var user = _repo.GetUserAsync(id).Result;` in a controller. What is wrong, and would it deadlock in ASP.NET Core?*
   A strong answer covers sync-over-async blocking a pool thread and the starvation risk under load. It usually does not deadlock in ASP.NET Core, which has no `SynchronizationContext`, but it can deadlock in UI apps or classic ASP.NET. The fix is to await it and make the action `async Task<...>`.
4. *When would you use `Task.Run` in a web API, and when should you not?*
   A strong answer covers that you should not use it for I/O, or to "async-ify" a synchronous API, or as `await Task.Run(...)` in request code. Long CPU-bound work is better moved to a background service or queue.
5. *Why is `async void` dangerous in ASP.NET Core, and where is it acceptable?*
   A strong answer covers that the caller cannot await or observe it, exceptions can crash the process, and the request may complete before the work does. It is acceptable only for event handlers.
6. *You call three independent services. How do you run them concurrently, and how do you handle a failure?*
   A strong answer covers starting the tasks, then `await Task.WhenAll`. `await` rethrows only the first exception, so inspect each task's `Exception` to see them all. Flow a `CancellationToken`.
7. *Do you need `ConfigureAwait(false)` in an ASP.NET Core controller? In a NuGet library?*
   A strong answer says no in app code (there is no `SynchronizationContext`) and yes in general-purpose libraries, to avoid deadlocks and needless context switches.
8. *(Stretch) When would you return `ValueTask<T>` instead of `Task<T>`?*
   A strong answer covers hot paths that often complete synchronously, such as cache hits, to avoid an allocation. A `ValueTask` must be awaited only once.

## Hands-on Exercises
Each exercise fits one 30-minute session. Use a local .NET 10 SDK.

1. **Watch the state machine (console, 30 min).**
   - *Goal:* see that `await` frees the thread and does not create one.
   - *Steps:* write an `async Task Main` that logs `Environment.CurrentManagedThreadId` before and after `await Task.Delay(500)`. Add a method marked `async` with no `await` and read the compiler warning. Then start three `Task.Delay(1000)` calls sequentially, and again with `Task.WhenAll`, timing both with `Stopwatch`.
   - *Observe:* the thread ID can change after the `await`. The sequential run takes about 3 s and `WhenAll` about 1 s. The warning confirms that a method without `await` runs synchronously.
2. **Thread-pool starvation in a minimal API (60 min, split over two sessions).**
   - *Goal:* measure the backend impact of sync-over-async.
   - *Steps:* create `dotnet new web`. Add `/sync`, which runs `Task.Delay(500).Wait(); return "ok";`, and `/async`, which runs `await Task.Delay(500); return "ok";`. Load each with about 200 concurrent requests (for example, a small `HttpClient` console loop using `Task.WhenAll`, or any load tool you have). Optionally watch `dotnet-counters monitor -n <app> System.Runtime` and look at the thread-pool thread count and queue length.
   - *Observe:* `/sync` latency climbs and the thread-pool thread count grows slowly. `/async` stays near 500 ms with few threads.
3. **Fix-the-bugs code review (30 min).**
   - *Goal:* practice spotting async bugs the way an interviewer would ask.
   - *Steps:* write a controller with four planted bugs: an `async void` action, `.Result` on a repository call, `await Task.Run(() => _repo.GetAsync())`, and three independent awaits run sequentially. Fix each one, add `CancellationToken ct` to the action, and pass it down.
   - *Observe:* explain each fix out loud in one sentence. That is your interview answer.
4. **Cancellation and WhenAll exceptions (30 min).**
   - *Goal:* understand faulted vs. cancelled states and multiple exceptions.
   - *Steps:* run `Task.WhenAll` over two tasks that throw different exceptions. Catch the exception and print `ex.GetType()`, then print each task's `Exception`. Next, use `new CancellationTokenSource(TimeSpan.FromMilliseconds(200))` with `Task.Delay(1000, cts.Token)` and print `task.Status`.
   - *Observe:* `await` surfaces one exception and the tasks hold all of them. The cancelled task's status is `Canceled`, with `Exception == null`.

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

## Gaps and Limitations
- **Seniority mismatch.** The agent template targets Senior. `requirements.md` states **Middle**, so the content is pitched at Middle, and the extra-credit items are marked "Stretch."
- **Unverified claim.** The claim that one EF Core `DbContext` must not run concurrent operations comes from general EF Core knowledge. No source was fetched for it in this session. The data-researcher area or the EF Core docs should confirm it before the plan relies on it.
- **Not verified.** The exact `dotnet-counters` counter names and output in Exercise 2 were not checked against the docs. Treat them as optional observation aids.
- **`ValueTask` guidance.** This guidance (stretch question 8) rests on the AsyncGuidance summary and general knowledge. No dedicated Microsoft Learn `ValueTask` page was fetched.
- **Fetch method.** The ConfigureAwait FAQ and AsyncGuidance pages were read through `WebFetch`, which returns summarized extracts. Claims attributed to them are limited to what those extracts showed.
- No tool failures occurred.
