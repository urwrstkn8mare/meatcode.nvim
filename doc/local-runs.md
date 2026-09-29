# Local test runs

`<leader>nr` runs the visible and user-written test cases. Opening a problem
discovers and caches every available oracle, with status messages for the
statement, each provider and each solution source, then validates the local
ones in the background (below). Local oracles need no network; the cloud oracle
is the submit judge's own test run.

Oracle selection is **stage-major**, strongest first:

1. **openleetcode checker.** [openleetcode](https://github.com/therepanic/openleetcode)
   publishes open LeetCode test manifests, most of them with a Python checker
   that decides whether *any* output is correct for *any* input — exact even
   when a problem accepts several answers.
2. **Reference solution.** NeetCode publishes one for every problem it carries.
3. **Official editorial.** Free LeetCode editorials embed runnable Python/C++
   implementations in playgrounds. Premium-gated or prose-only editorials
   simply fall through.
4. **Popular community solution.** LeetCode candidates arrive most-voted first;
   LintCode candidates are sorted by their like count. Arbitrary community code
   is not trusted on reputation alone: it is only considered when at least one
   answer is known.
5. **Cloud.** The submit provider's test run — LeetCode's and NeetCode's "Run",
   LintCode's "Test" — checked against cached answers first (below).

The configured content-provider fallback chain applies **inside every stage**.
For example, a NeetCode reference still beats a LeetCode editorial even when
LeetCode is the preferred statement provider; provider preference only breaks
ties between candidates in the same stage.

Every local oracle can judge any input, including cases you wrote. The results
panel names the oracle actually used.

`<leader>ns` remains the real judge and runs the hidden suite.

## The cloud oracle

The cloud oracle is always cautious. Its test run starts alongside your local
run; if every output matches a cached correct answer it is cancelled on the
spot and nothing waits for it. Otherwise the judge settles every case that did
not match — including outputs that are merely ordered differently — with its
own checker, so a different but valid answer (`"bab"` where the cache has
`"aba"`) passes. Its answers, and any differing output of yours it accepted,
join the answer cache, so the next run settles those cases locally.

It judges when:

- no local oracle is selected yet (validation still running, or every candidate
  rejected);
- the problem cannot run locally at all — languages other than Python and C++,
  SQL, arguments passed by reference (`clone-graph`), C++ `vector<Interval>`.
  Every case then runs on the judge;
- the **cloud oracle** setting says so. `<leader>nc` has a row for it, cycled
  with `<CR>` and saved for every problem:
  - *complex problems without an openleetcode checker* (default) — problems
    NeetCode marks as having no single exactly comparable output
    (`complexTestCases`: Longest Palindromic Substring, Course Schedule II,
    Alien Dictionary, the "any order" ones). A checker already judges those
    exactly, so it overrides this default;
  - *every problem*;
  - *never* — only as the fallback above.

The test run uses your submit chain's judge and needs its login
(`:MeatCode login ...`). The local suite is converted to that judge's input
format: labels added or dropped, design cases re-laid out between LeetCode's
two lines and NeetCode's single interleaved line. When the test run cannot
happen (not logged in, offline, rate-limited, refused), cases are graded
against cached answers alone and marked as having no verdict from the judge;
a case with no cached answer shows `RAN` with expected output `N/A`.

Judges have limits: NeetCode accepts at most four cases per run, so larger
suites go out in batches; LeetCode rate-limits runs fired in quick succession;
LintCode takes one input per run and reuses a single test slot per problem, so
cases go one at a time and each result is only trusted once the slot has moved
on (roughly ten seconds per case).

When the cloud oracle judges while a local oracle is selected (a forced run)
and the judge contradicts that oracle's cached output on a problem with a
single right answer, the oracle is blacklisted on the spot and the next
candidate is validated.

## openleetcode checkers

Opening a problem looks its LeetCode slug up in openleetcode's manifest index
(cached under `stdpath("cache")/meatcode/openleetcode/`, refreshed every
`catalog_max_age`). A manifest's `oracle.python3` section — a `Checker` class
plus a call such as `Checker().longestPalindrome(s, {result})` — becomes the
first candidate. Checkers exist for function problems only; openleetcode
carries no design problems.

The checker is remote code: it always runs sandboxed, in Python, whatever your
solution's language, so it needs `runner.python.cmd` even for C++. It is
validated like any candidate — it must accept every known answer — and, once
selected, grades each of your outputs after your code runs. Outputs it accepts
join the answer cache.

## The answer cache

Every oracle feeds one cache of correct answers per problem,
`stdpath("cache")/meatcode/known-answers/<problem>.json`. Each input maps to
every answer known for it and where it came from:

- the judge — an answer disclosed by a failed submission, or a test run's
  answer and any differing output of yours it accepted;
- the statement — answers printed in LeetCode/LintCode examples, read from the
  metadata rather than stored;
- the selected local oracle — a reference/editorial/community output, or an
  output the checker accepted.

Judge and statement answers are ground truth. A local oracle's answers only
count while it is the selected oracle, and are dropped when it is rejected.
Inputs are matched by content with argument labels dropped, so NeetCode's
`nums=[1,2]` and LeetCode's `[1,2]` share answers. Your output passes when it
matches any answer for its input.

## Background validation

Local candidates are validated in the background as soon as the problem opens,
one at a time in the order above. Each is sandboxed and must agree with every
known answer — statement answers and answers learned from failed submissions,
any of the acceptable answers where an input has several. A reference or
editorial with no known answers only has to run the visible examples cleanly;
a checker with none only has to load. A wrong answer, exception, compile error,
crash or timeout **blacklists** the candidate permanently for that problem and
language (`stdpath("cache")/meatcode/oracle-validations/`), and the next one is
tried until one survives or none remain. Coming back later — or another
provider adding candidates — only ever tries candidates that have not been
seen, so a fully checked problem re-runs no provider code at all. A stronger
stage that appears later (e.g. the checker, once fetched) is tried before the
current selection. A missing sandbox, a missing Python for the checker, or a
problem that cannot run locally stops the pass without blacklisting anything.

A surviving reference/editorial/community candidate immediately precomputes its
outputs for your current suite. Test-run answers are not part of validation, so
a run that learns some does not force a revalidation.

A local run never waits on any of this: until a candidate is selected the cloud
oracle judges (the results panel says validation is still in progress).

## What runs locally

Python and C++, for both `function` problems and `class` ("design") problems.
Handled:

- integers, floats, booleans, `char`, strings, and nested `vector`/`list` of
  those
- `ListNode` and `TreeNode`, array-encoded exactly as LeetCode does — including
  `List[ListNode]` (merge-k-sorted-lists) and scalars that identify an existing
  node inside another argument (`lowestCommonAncestor`'s `p` and `q`)
- helper classes such as `Interval`, recovered from the docstring the reference
  solution carries
- in-place problems that mutate their first argument and return nothing
- 32-bit values passed as zero-padded binary strings (`reverse-bits`)
- reference solutions whose parameter names differ from the test case keys —
  arguments are bound positionally, as are LeetCode's and LintCode's unlabelled
  inputs (one bare value per line) and LintCode's prose labels
  (`binary tree = {1,2,3}`, whose `{…}`/`#` node encoding is read as LeetCode's
  `[…]`/`null`)
- design problems (Min Stack, LRU Cache, Trie, Design Twitter, ...): the call
  sequence is replayed against your class and the selected executable oracle,
  or compared with a known answer list. Both input encodings are decoded —
  LeetCode's two-line `names` / `args` pair, and NeetCode's interleaved
  `["MinStack", "push", 1, ...]` form, whose argument boundaries are recovered
  from the arities in the starter code
- encode/decode pairs (Serialize and Deserialize Binary Tree, Encode and Decode
  Strings), judged by round-tripping the input through both halves
- test cases that quote their numbers (`"1"` rather than `1`), coerced to the
  parameter's declared type

## What doesn't

SQL, languages other than Python and C++, and problems that encode their
arguments **by reference** rather than by value: the adjacency list in
`clone-graph`, the random pointers in `copy-linked-list-with-random-pointer`.
Those cannot be faithfully rebuilt from the input, so they run entirely on the
submit judge's test run instead of reporting a bogus diff. C++ additionally
cannot take `vector<Interval>` (`meeting-schedule`), which Python handles.

Across the NeetCode 150 that is 148/150 runnable locally in Python and 146/150
in C++.

When your output matches a known answer only up to ordering, the case is
reported as passing with a note; under the cloud oracle the judge makes that
call instead.

## Editing the case list

`<leader>nt` opens the local suite in an editor. Cases are separated by a line
containing `---`; delete a whole case to remove it. `:w` saves, `:q` closes,
and a local run saves pending edits for you.

```text
nums=[1,2,3,4]
target=7
---
nums=[0,0]
target=0
```

`<leader>na` appends the input from the last failed submission and saves,
skipping duplicates. When that verdict includes an expected output, the pair
joins the answer cache. Known answers changed, so the local oracle is rechecked
in the background: if it fails the new answer it is blacklisted and the next
candidate is tried. The outcome is reported under the verdict.

The suite lives in `<solution-file>.cases`. Before you first save it, it is the
visible cases plus any legacy `.tests` extras; once saved, the file *is* the
suite. An empty `.cases` runs nothing. Delete it to go back to the defaults.
None of this affects what gets submitted.

**Legacy `.tests` files.** A `<solution-file>.tests` next to your solution, in
the same `---`-separated format, is still read and folded into the initial
suite.

## Performance

Cases are independent, so Python and C++ function, design and round-trip suites
run in separate worker processes. `runner.parallelism = 0` (the default) uses
the smaller of the case count and available CPU count; `1` is sequential and a
larger number is an explicit worker cap. Shard reports are merged back into
original case order, so output stays deterministic.

The selected oracle is cached by its source hash and the fingerprint of every
known answer, next to the blacklist. Reopening a problem, even in a new Neovim
session, re-runs no provider code, and editing the local suite does not
invalidate the selection. A new answer from a failed submission changes the
fingerprint, which rechecks the selection in the background.

Set `parallelism = 1` for solutions that intentionally share process-global or
filesystem state across otherwise independent cases.

## When C++ crashes

A hard crash keeps its signal number and gets a plain-English diagnosis where
one is known — `SIGSEGV` for invalid memory access, `SIGBUS` for invalid or
misaligned access. If LLDB is installed the harness reruns once, only after a
crash, and appends a source backtrace. The visible test case that was running
is named when the harness had got far enough to start one.

## Running provider code safely

Reference, editorial and community implementations and openleetcode checkers
are remote code. They never share a process with your solution. With the
default `runner.sandbox = true`, oracle validation, checker grading and any
first-time computation of an oracle's output for a test case run without
network access and without access to your home directory/repository; the
per-run scratch directory is the only place under your home they can write.
Those outputs go into the answer cache: known answers during validation, your
current suite right after selection. A later local run only sandboxes the
oracle again for cases you have since added or edited. Your own code then runs
alone, outside the sandbox, against the cached answers. Background and
foreground oracle work use separate scratch directories from your runs, so they
never collide.

On Linux isolation means fresh user, PID, network, IPC and mount namespaces via
bubblewrap (`bwrap`), exposing `/usr`, the dynamic loader cache and minimal
`/dev` read-only; the scratch directory and a private tmpfs `/tmp` are the only
writable places. On macOS `sandbox-exec` applies a Seatbelt profile that denies
the network, `/Users`, your home directory and `/Volumes`, re-allowing only the
scratch directory; the rest of the filesystem keeps normal permissions, so
shared locations such as `/tmp` stay writable, and macOS has no PID namespace,
so the host process table stays visible. Both clear the environment.

This materially limits ordinary malicious code, but is not a VM: it shares the
host kernel, has no memory/cgroup quota, and compiler/interpreter/kernel
vulnerabilities remain in scope. The existing wall-clock timeout limits CPU
loops but not every denial-of-service shape.

If `bwrap` (Linux) or `sandbox-exec` (macOS) is unavailable, provider-supplied
candidates fail closed (without being blacklisted) and runs use the cloud
oracle. Setting `runner.sandbox = false` opts out and runs provider code with
your full user permissions: it could read SSH keys/tokens, modify files, use
the network, spawn processes or otherwise do anything your account can do.
