# Python and your language server

Starter code for Python has no `from typing import ...`, and no definition of
`ListNode` / `TreeNode` / a problem-specific `Node` / `Interval`. The judge
supplies all of it implicitly — `Optional`, `List`, `ListNode` and friends are
already in scope by the time your `Solution` class runs. A language server
does not know that, so a perfectly valid solution lights up with
undefined-name diagnostics.

C++ solves the same problem by force-including a header only clangd sees (see
[cpp.md](cpp.md)) — the solution file itself is never touched. Pyright and
pylsp have no equivalent: there is no way to put a name in scope without it
actually being there. So instead, the plugin inserts a real, clearly-marked
block at the top of your solution file, and strips exactly that block back out
before every local run and every submission. `runner.python.auto_imports =
false` turns it off.

## What gets inserted

```python
# --- meatcode: auto-imports for your editor (stripped before running/submitting) ---
from typing import *


class ListNode:
    def __init__(self, val=0, next=None):
        self.val = val
        self.next = next
# --- meatcode: end auto-imports ---

class Solution:
    def addTwoNumbers(self, l1: Optional[ListNode], l2: Optional[ListNode]) -> Optional[ListNode]:
        ...
```

- `from typing import *` only appears when the starter actually mentions a
  `typing` name (`Optional`, `List`, `Dict`, `Union`, ...). A problem like "A +
  B" that only uses `int` gets no header at all.
- The helper type is lifted from the starter's own leading comment or
  docstring — the same `# class ListNode: ...` (LeetCode, NeetCode) or
  `"""Definition of ListNode: class ListNode(object): ..."""` (LintCode) text
  every provider already ships to document the type its judge injects. This is
  per-problem, the same way the C++ header is: "Copy List with Random Pointer"
  gets a `Node` with a `random` field, "Clone Graph" gets one with
  `neighbors`, because each is lifted from that problem's own starter instead
  of a single generic shape.
- When a starter names `ListNode`/`TreeNode` but carries no such comment, the
  plugin falls back to the same shape
  `lua/meatcode/runner/harness/python.py`'s local-run harness already injects
  for every problem, so editing and running never disagree about the shape.

## Guarantees

- A local run and a submission both see your solution with the block removed
  — never anything beyond what you wrote. `lua/meatcode/runner/python_prelude.lua`
  is the single strip point both flow through.
- Resetting to starter code (`<leader>nR`) re-inserts the block; it is
  re-derived from the starter each time, never hand-maintained.
- The block only ever appears when something in the starter looks like it
  needs it. Nothing is inserted for a problem that needs none of it.
