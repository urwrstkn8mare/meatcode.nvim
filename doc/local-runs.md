# Local test runs

`<leader>nr` runs the visible and user-written test cases locally. Opening a
problem discovers and caches every available oracle, with status messages for
the statement, each provider and each solution source. Execution itself then
needs no network.

Oracle selection is **stage-major**, strongest first:

1. **Reference solution.** NeetCode publishes one for every problem it carries.
2. **Official editorial.** Free LeetCode editorials embed runnable Python/C++
   implementations in playgrounds. Premium-gated or prose-only editorials
   simply fall through.
3. **Popular community solution.** LeetCode candidates arrive most-voted first;
   LintCode candidates are sorted by their like count. Arbitrary community code
   is not trusted on reputation alone: every candidate must pass every visible
   case with a known answer. A failure, syntax error or incompatible signature
   advances to the next candidate.
4. **Known answers.** Answers printed in LeetCode/LintCode statements judge the
   examples they belong to. Answers disclosed by a failed cloud submission are
   cached by problem and exact input and join this set.

The configured content-provider fallback chain applies **inside every stage**.
For example, a NeetCode reference still beats a LeetCode editorial even when
LeetCode is the preferred statement provider; provider preference only breaks
ties between candidates in the same stage.

An executable solution oracle can judge any input, including cases you wrote.
Under the final answer-only stage, an unknown custom case still executes and is
shown as `RAN` with expected output `N/A`. After the cloud judge reveals an
answer for that exact input, later local runs grade it normally. The results
panel names the source ultimately selected.

`<leader>ns` remains the real judge and runs the hidden suite.

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

SQL, and problems that encode their arguments **by reference** rather than by
value: the adjacency list in `clone-graph`, the random pointers in
`copy-linked-list-with-random-pointer`. Those cannot be faithfully rebuilt from
the input, so the plugin says so instead of reporting a bogus diff and points
you at `<leader>ns`, which always works. C++ additionally cannot take
`vector<Interval>` (`meeting-schedule`), which Python handles.

Across the NeetCode 150 that is 148/150 runnable locally in Python and 146/150
in C++.

The layered source chain expands coverage beyond statements, but does not make
every problem faithfully reproducible. A supported starter with visible inputs
can always execute; without a surviving source or known answer its output is
`RAN`/`N/A`. SQL, missing Python/C++ starters, and by-reference structures
remain non-runnable for the reasons above.

When your output matches the reference only up to ordering, the case is
reported as passing with a note. The real judge makes the final call.

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
skipping duplicates. When that verdict includes an expected output, the pair is
also persisted under `stdpath("cache")/meatcode/known-answers/`; it is matched by
normalised input content rather than case position. If the last local oracle
was a community solution, it is immediately checked against the new answer.
A failure discards it for the session and tries the next popular candidate,
falling back to known answers when none survive.

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

The first executable oracle is sanity-checked as described above. Its source
hash and the complete known-answer fingerprint are then cached under
`stdpath("cache")/meatcode/oracle-validations/`. Repeated runs — including after
reopening Neovim — skip that extra interpreter/compiler pass. A new answer from
a failed submission changes the fingerprint immediately, forcing revalidation.

Set `parallelism = 1` for solutions that intentionally share process-global or
filesystem state across otherwise independent cases.

## When C++ crashes

A hard crash keeps its signal number and gets a plain-English diagnosis where
one is known — `SIGSEGV` for invalid memory access, `SIGBUS` for invalid or
misaligned access. If LLDB is installed the harness reruns once, only after a
crash, and appends a source backtrace. The visible test case that was running
is named when the harness had got far enough to start one.

## Running provider code safely

Reference, editorial and community implementations are remote code. They never
share a process with your solution. With the default `runner.sandbox = true`,
oracle validation and any first-time computation of an oracle's output for a
test case run isolated from the network, the home directory/repository and the
rest of the host filesystem, with only the per-run scratch directory writable.
Those outputs are cached per problem, language and exact input under
`stdpath("cache")/meatcode/oracle-outputs/` during the same sandboxed pass that
validates the oracle against known answers, so known cases are never re-run.
A later local run only sandboxes the oracle again for cases you added or
edited. Your own code then runs alone, outside the sandbox, against the
cached answers.

On Linux isolation means fresh user, PID, network, IPC and mount namespaces via
bubblewrap (`bwrap`), exposing `/usr`, the dynamic loader cache and minimal
`/dev` read-only. On macOS `sandbox-exec` applies a Seatbelt profile with the
same scope; macOS has no PID namespace, so the host process table stays
visible. Both clear the environment.

This materially limits ordinary malicious code, but is not a VM: it shares the
host kernel, has no memory/cgroup quota, and compiler/interpreter/kernel
vulnerabilities remain in scope. The existing wall-clock timeout limits CPU
loops but not every denial-of-service shape.

If `bwrap` (Linux) or `sandbox-exec` (macOS) is unavailable, provider-supplied
executable candidates fail closed and selection continues toward statement/
learned answers. Setting `runner.sandbox = false` opts out and runs provider
code with your full user permissions: it could read SSH keys/tokens, modify
files, use the network, spawn processes or otherwise do anything your account
can do.
