# Local test runs

`<leader>nr` runs the visible test cases without touching the network.

That is possible because of an asymmetry: expected outputs are kept
server-side, but NeetCode publishes its own **reference solution** for every
problem, unauthenticated. So a local run executes your code *and* the reference
over the same inputs and diffs the two. No rate limit, no round trip, instant
feedback.

`<leader>ns` is still the real judge — it submits to LeetCode (or NeetCode)
and runs the hidden suite.

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
  arguments are bound positionally
- design problems (Min Stack, LRU Cache, Trie, Design Twitter, ...): the call
  sequence is replayed against both your class and the reference class and the
  two lists of return values are diffed. Both encodings are decoded —
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
skipping duplicates.

The suite lives in `<solution-file>.cases`. Before you first save it, it is the
visible cases plus any legacy `.tests` extras; once saved, the file *is* the
suite. An empty `.cases` runs nothing. Delete it to go back to the defaults.
None of this affects what gets submitted.

**Legacy `.tests` files.** A `<solution-file>.tests` next to your solution, in
the same `---`-separated format, is still read and folded into the initial
suite.

## When C++ crashes

A hard crash keeps its signal number and gets a plain-English diagnosis where
one is known — `SIGSEGV` for invalid memory access, `SIGBUS` for invalid or
misaligned access. If LLDB is installed the harness reruns once, only after a
crash, and appends a source backtrace. The visible test case that was running
is named when the harness had got far enough to start one.
