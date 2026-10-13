# Validation: coverage

**Verdict: pass** (0 blocking, 2 advisory)

| Mandatory topic | Status | Evidence |
|---|---|---|
| async/await in C# | covered | research/dotnet.md, mapped section: findings, pitfalls, backend example, 8 interview questions, 4 exercises, pitched at Middle level |

## Blocking findings

None.

## Advisory findings

- **C1** (dotnet-researcher, unsupported_claim): the note that one EF Core DbContext must not run concurrent operations has no citation (the artifact discloses this). Cite the EF Core DbContext threading docs or present it as general guidance.
- **C2** (dotnet-researcher, unsupported_claim): the ValueTask guidance in stretch question 8 has no Microsoft Learn source. Optional.

## Optional recommendations

- Exercises total 150 of the 180 budgeted minutes (Exercise 2 spans two sessions), so the planner has 30 minutes for theory and question review.
- Treat the dotnet-counters names in Exercise 2 as optional, because they were not verified.

## Claim checks

1 Microsoft Learn page fetched: ASP.NET Core Best Practices (aspnetcore-10.0). It confirms the claims about blocking calls and thread-pool starvation, not using `Task.Run` and immediately awaiting it, `async void` always being bad practice in ASP.NET Core, and late `HttpResponse` access crashing the process. No fetch failures.
