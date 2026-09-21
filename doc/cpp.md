# C++ and your language server

Starter code for C++ has no `#include`s, no `using namespace std;`, and no
definition of `ListNode` / `TreeNode` / `Node` / `Interval`. The judge supplies
all of it implicitly. A language server does not, so a perfectly valid solution
lights up red.

Rather than editing your solution, the plugin writes a `.clangd` next to your
solutions directory. It is on by default; `runner.cpp.clangd = false` turns it
off.

## What gets written

```text
solutions/
├── .clangd                 # one fragment per problem, PathMatch-scoped
└── .meatcode/
    ├── prelude.h           # standard library + using namespace std
    ├── clone-graph.h       # class Node { vector<Node*> neighbors; ... }
    └── meeting-schedule.h  # class Interval { int start, end; ... }
```

The config force-includes `prelude.h` for every solution, plus a **per-problem
header holding that problem's own helper types**, lifted from the definition
NeetCode leaves in its starter comment.

Per-problem rather than shared, because there is no single right answer:
`Node` is an adjacency list in Clone Graph and a random pointer in Copy List
with Random Pointer. Each problem gets the one it actually has, so
`node->random` is correctly rejected in Clone Graph instead of quietly
accepted.

Compile flags — including `-std` — are taken from `runner.cpp.cmd`, so clangd
parses your file in the same language mode the local runner compiles it in.

## Guarantees

- Your solution file is left exactly as the provider wrote it. Nothing is
  inserted into it and nothing extra is submitted.
- Headers are written when you open a problem, and `.clangd` is rebuilt from
  whatever headers exist on disk, so the two never drift.
- A `.clangd` the plugin did not write is left alone **only** if it already
  matches `runner.cpp.cmd` (same `-std` / `-stdlib`). A stale or conflicting
  one is overwritten.

Measured over seeded solutions, `clangd --check` goes from 1–4 errors per file
to zero.
