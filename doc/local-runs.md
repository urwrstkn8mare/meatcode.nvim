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
- the problem cannot run locally — languages without a local harness, SQL,
  unsupported signatures or opaque/reference encodings that do not declare
  their identity (`clone-graph` adjacency lists). Every case then runs on the judge;
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

Python, C++, Swift and Rust support function problems, in-place mutation,
`class` ("design") operation suites, and encode/decode round trips. Rust uses
only `rustc` and the standard library; no Cargo project or downloads.

Custom helper records are recovered from starter comments/docstrings and actual
starter, solution and reference declarations. Missing definitions and typed
codecs are generated in scratch harnesses, never added to your solution file
or submitted payload. Helper names are not special: `Point`, `Packet`, `Node`
and `Interval` use their declared fields.

Records accept positional arrays, NeetCode tuples (JSON `null`, `true` and
`false` inside parentheses included), or named JSON objects. Named
keys address stored fields; positional values follow constructor parameter order
when it maps unambiguously to those fields, otherwise field declaration order.
Returns serialize in that same positional order. Nested records, collections,
string-key maps and optional/null fields use the same codecs. Declared defaults
may fill omitted fields; missing required fields, surplus values and wrong
shapes fail explicitly.

Reference-capable records also accept explicit identity objects:

```text
root={"$id":"root","value":1,"next":{"$ref":"root"}}
```

`$id` is a nonempty string or integer; a reference contains only `$ref`.
Definitions are indexed across all arguments and design operations in one case,
so forward references, shared objects and representable cycles retain identity.
Returns with explicit identity, sharing or cycles use named objects with
canonical integer IDs starting at 1. IDs are isolated between cases and between
user/reference executions. Duplicate IDs, unresolved/wrong-type references and
identity tags on value structs fail explicitly. `$id` and `$ref` are reserved
keys, including inside maps.

Additional coverage includes:
- integers, floats, booleans, characters, strings and nested collections
- standard `ListNode` and `TreeNode`, array-encoded as LeetCode does, including
  node collections and existing-node arguments (`lowestCommonAncestor`'s `p`/`q`)
- `Interval` collections, including JSON arrays (`[[0,30],[5,10]]`) and
  NeetCode tuples (`[(0,30),(5,10)]`), without modifying your solution
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

SQL and opaque provider reference encodings remain cloud only. The adjacency
list in `clone-graph` and random-pointer indices in
`copy-linked-list-with-random-pointer` are not explicit `$id`/`$ref` schemas;
the harness does not guess their edges.

Custom records require accessible stored fields and a safe constructor mapping.
C++ requires direct public data fields and unambiguous constructor assignments;
in-class default field initializers are unsupported.
Python constructors must map parameters one-to-one to stored attributes; slots
are supported. Swift supports structs/classes, with mutable, safely initialized
class fields required for cyclic identity shells. Rust supports named structs,
`Box<T>` values and `Rc<RefCell<T>>` identity graphs; tuple/unit structs and
borrowed-reference fields are unsupported. Unsupported field types, ambiguous
constructors and unsafe cyclic layouts are reported rather than fabricated,
and retain the existing cloud fallback.

The historical NeetCode 150 counts below describe the earlier Python/C++
coverage, not a measured Swift/Rust coverage figure.

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

Cases are independent, so all four languages' function, design and round-trip
suites run in separate worker processes. `runner.parallelism = 0` uses
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

Local C++ builds follow LeetCode's judge: `-O2` with AddressSanitizer, plus
UndefinedBehaviorSanitizer and libc++'s debug-mode hardening. An out-of-bounds
access, use-after-free, null dereference, signed overflow, stack overflow or
invalid `std::sort` comparator therefore stops a local run as it would a
submission. The hardening matters on macOS: libc++ keeps short strings inside
the `std::string` object, so reading just past the end of one stays inside the
object where AddressSanitizer cannot see it, while the same read overflows
LeetCode's libstdc++ string and fails there. The checks are stricter than
LeetCode in one way: indexing a `std::vector` past `size()` fails even when it
stays within the allocated capacity. On Linux the sanitizers need GCC's
`libasan`/`libubsan` or Clang's runtime; drop the `-fsanitize` flags from
`runner.cpp.cmd` if your toolchain lacks them.

A crash is reported against the test case that was running, with its input:
what went wrong, the line of your solution where it happened (with the source
line, plus the column for undefined behaviour), the calls in your code that led
there, where the heap memory involved was allocated (and freed, for a
use-after-free), and the last 40 lines your solution printed before it died.
The complete report is saved to `crash.log` in the run's scratch directory,
whose path the panel shows. When several cases crash, the earliest is reported;
a timeout is reported against its case the same way.

Without the sanitizers (a `runner.cpp.cmd` of your own), a crash keeps its
signal number and gets a plain-English diagnosis where one is known —
`SIGSEGV` for invalid memory access, `SIGBUS` for invalid or misaligned access,
`SIGTRAP` for a failed runtime check. If LLDB is installed and one worker ran
the suite, the harness reruns once under it and appends a source backtrace.

## Running provider code safely

Reference, editorial and community implementations and openleetcode checkers
are remote code. They never share a process with your solution. With the
default `runner.sandbox = true`, oracle validation, checker grading and any
first-time computation of an oracle's output for a test case run without
network access, without access to your home directory/repository, and without
write access anywhere but the per-run scratch directory. Those outputs go into
the answer cache: known answers during validation, your current suite right
after selection. A later local run only sandboxes the oracle again for cases
you have since added or edited. Your own code then runs alone, outside the
sandbox, against the cached answers. Background and foreground oracle work use
separate scratch directories from your runs, so they never collide.

On Linux isolation means fresh user, PID, network, IPC and mount namespaces via
bubblewrap (`bwrap`), exposing `/usr`, the dynamic loader cache and minimal
`/dev` read-only; the scratch directory and a private tmpfs `/tmp` are the only
writable places. On macOS `sandbox-exec` applies a Seatbelt profile that denies
everything it does not list. Provider code may read and run the toolchain and
system libraries (`/usr`, `/bin`, `/opt`, `/Applications`, `/Library/Developer`,
`/Library/Frameworks`, `/etc`), read Xcode's tool-lookup cache so
`/usr/bin/c++` and `/usr/bin/python3` start without a second's delay, and
read, write and run only inside the scratch directory, which also holds
`TMPDIR`. Everything else is denied: your home directory, `/Volumes`, the
shared temporary directories, the terminal, the network, and services such as
LaunchServices and the pasteboard. A toolchain installed under your home
directory therefore cannot run provider code. macOS has no PID namespace, so
the host process table stays visible. Both clear the environment.

Compiler/interpreter names are resolved against your `PATH` before clearing the
environment. macOS also permits metadata reads of the exact scratch-directory
ancestors so LLVM can validate its working directory; their contents remain
inaccessible.

This materially limits ordinary malicious code, but is not a VM: it shares the
host kernel, has no memory/cgroup quota, and compiler/interpreter/kernel
vulnerabilities remain in scope. The existing wall-clock timeout limits CPU
loops but not every denial-of-service shape.

If `bwrap` (Linux) or `sandbox-exec` (macOS) is unavailable, provider-supplied
candidates fail closed (without being blacklisted) and runs use the cloud
oracle. Setting `runner.sandbox = false` opts out and runs provider code with
your full user permissions: it could read SSH keys/tokens, modify files, use
the network, spawn processes or otherwise do anything your account can do.
