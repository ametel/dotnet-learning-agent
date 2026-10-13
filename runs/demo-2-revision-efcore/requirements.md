---
artifact: requirements
run_id: 20261012-193618-middle-backend-efcore-06d058
generated_by: requirements-formalizer
source: runs/20261012-193618-middle-backend-efcore-06d058/confirmed-input.md
blocking_open_questions: 0
mandatory_topics:
  - EF Core performance
  - Query optimization
  - AsNoTracking
  - N+1 queries
  - Indexing
time_budget_hours: 2.5
---

# Interview Preparation Requirements

## Summary
A Middle+ .NET backend developer is preparing for an interview in 7 days. Their only self-reported weak area is EF Core performance, and they want to cover query optimization, AsNoTracking, N+1 queries, and indexing. They can spend 30 minutes per day for 5 days (2.5 hours in total), and they prefer hands-on exercises and short interview questions.

## Target Role and Seniority
- Role: .NET backend (stated)
- Seniority: Middle+ (stated)
- Target company / domain / stack: Company and domain Unspecified. Stack: .NET backend (stated). Database provider and .NET / EF Core version are Unspecified.
- Interview format (if known): Unspecified

## Topics
| Topic | Priority | Label | Notes |
|---|---|---|---|
| EF Core performance | High | (stated) | The user's only stated knowledge gap |
| Query optimization | High | (stated) | Explicitly requested topic |
| AsNoTracking | High | (stated) | Explicitly requested topic |
| N+1 queries | High | (stated) | Explicitly requested topic |
| Indexing | High | (stated) | Explicitly requested topic |
| Inspecting the SQL that EF Core generates (logging / query diagnostics) | Low | (derived) | Supports Query optimization and N+1 queries. Optional, not mandatory. |

The priorities are derived. See *Open Questions and Assumptions*.

## Knowledge Gaps
- EF Core performance (stated). The user said: "My only weak area is EF Core performance".
- Requested sub-areas to cover (stated): Query optimization, AsNoTracking, N+1 queries, Indexing.

Known strengths: Unclear. The user named no strengths explicitly. Their statement "My only weak area is EF Core performance" implies that other areas are not weak, but it names nothing specific. Later agents should not schedule prep for other .NET areas. They should also not treat any specific topic as a confirmed strength.

## Time Availability
- Interview date or deadline: "Interview in 7 days" (stated). The exact date is Unspecified.
- Hours per week: Unspecified as a weekly figure. The user stated 30 minutes per day for 5 days (stated).
- Total preparation window: 5 study days within the 7 days before the interview. The total budget is 2.5 hours (stated).

## Learning Preferences
- Formats: hands-on exercises and short interview questions (stated).
- Depth versus breadth: Unspecified. Depth on a narrow topic set is implied by the focus on EF Core performance (derived).
- Language: Unspecified.
- Session length: 30 minutes per day (stated).

## Constraints
- Budget, tools, platforms, exclusions: Unspecified (stated as Unspecified by the user).
- Schedule limit: at most 30 minutes per day on 5 days, 2.5 hours in total (stated).

## Acceptance Criteria
1. Every mandatory topic (EF Core performance, Query optimization, AsNoTracking, N+1 queries, Indexing) is covered in the plan. (Traces to Knowledge Gaps and Topics.)
2. Every High-priority topic has at least one hands-on exercise. (Traces to Learning Preferences.)
3. Every High-priority topic has at least one short interview question with a model answer or key points. (Traces to Learning Preferences.)
4. The schedule totals no more than 2.5 hours, with no day over 30 minutes and no more than 5 study days. (Traces to Time Availability and Constraints.)
5. All study days fall within the 7 days before the interview. (Traces to Time Availability.)
6. The content is pitched at Middle+ level for a .NET backend role: practical trade-offs and diagnosis, beyond definitions. (Traces to Target Role and Seniority.)
7. The plan does not schedule preparation for .NET areas outside EF Core performance, except optional derived support topics that fit within the budget. (Traces to Knowledge Gaps.)
8. The plan restates every assumption from *Open Questions and Assumptions* that influences its content, for example the database provider and .NET version. (Traces to Open Questions and Assumptions.)

## Open Questions and Assumptions
1. [non-blocking] Exact interview date is Unspecified. The user said "Interview in 7 days". Assume: the interview is about 7 days after the run date (around 2026-10-19).
2. [non-blocking] Which 5 of the 7 days are study days is Unspecified. Assume: 5 study days before the interview, leaving slack days for rest or overflow.
3. [non-blocking] Seniority "Middle+" is kept in the user's words. Derived interpretation: between middle and senior. Expect questions on practical trade-offs and diagnosis, not on system-level architecture leadership.
4. [non-blocking] Known strengths are Unclear. The user said "My only weak area is EF Core performance" and named no strengths explicitly. Assume: general .NET backend knowledge is adequate. Do not plan for other areas, and do not list specific strengths.
5. [non-blocking] Constraints (budget, tools, platforms, exclusions) are Unspecified. Assume: free resources and a local development setup (the .NET SDK and a local database) are acceptable for exercises.
6. [non-blocking] Target company / domain is Unspecified. Assume: a generic .NET backend interview.
7. [non-blocking] Interview format is Unspecified. Assume: a technical interview with verbal questions and possibly a short coding or code-review exercise.
8. [non-blocking] .NET and EF Core versions are Unspecified. Assume: the latest LTS .NET and the matching EF Core version.
9. [non-blocking] Database provider is Unspecified. This matters for Indexing and query plans. Assume: a relational database, using SQL Server as the default example, and note where the advice is provider-specific.
10. [non-blocking] Language of learning materials is Unspecified. Assume: English.
11. [non-blocking] Depth versus breadth is Unspecified (derived). Assume: depth on the stated EF Core performance topics, because that is the only stated gap and the budget is small.
12. [non-blocking] Topic priorities are derived. All stated and requested topics are High because they are the user's only stated gap and explicit requests. The derived support topic is Low.
13. [non-blocking] Derived topic "Inspecting the SQL that EF Core generates (logging / query diagnostics)" was added as optional support for Query optimization and N+1 queries. It is not mandatory. Assume: include it only if it fits within the 2.5-hour budget.
14. [non-blocking] time_budget_hours = 2.5 comes from the user's stated total. It is consistent with the stated 30 minutes/day × 5 days = 150 minutes = 2.5 hours (derived check). Assume: 2.5 hours is a hard cap.
