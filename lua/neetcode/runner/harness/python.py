"""Local test harness for neetcode.nvim (Python).

NeetCode keeps expected outputs server-side, so we recover them by running the
site's own reference solution against the same inputs and diffing. Both the user
solution and the reference run in isolated namespaces seeded with the type names
their annotations expect (List, Optional, ListNode, TreeNode, ...).

Usage: python3 python.py <workdir>
Reads user.py, ref.py and cases.json from <workdir>; writes a JSON report to stdout.
"""
import ast
import copy
import inspect
import io
import json
import re
import os
import sys
import time
import traceback
import typing


class ListNode:
    def __init__(self, val=0, next=None):
        self.val = val
        self.next = next


class TreeNode:
    def __init__(self, val=0, left=None, right=None):
        self.val = val
        self.left = left
        self.right = right


def build_list(values):
    head = None
    for v in reversed(values or []):
        head = ListNode(v, head)
    return head


def dump_list(node):
    out, seen = [], set()
    while node is not None:
        if id(node) in seen:            # guard against cycles in buggy code
            out.append("<cycle>")
            break
        seen.add(id(node))
        out.append(node.val)
        node = node.next
    return out


def build_tree(values):
    """LeetCode level-order encoding, with None for absent children."""
    values = values or []
    if not values or values[0] is None:
        return None
    root = TreeNode(values[0])
    queue, i = [root], 1
    while queue and i < len(values):
        node = queue.pop(0)
        if i < len(values):
            v = values[i]; i += 1
            if v is not None:
                node.left = TreeNode(v)
                queue.append(node.left)
        if i < len(values):
            v = values[i]; i += 1
            if v is not None:
                node.right = TreeNode(v)
                queue.append(node.right)
    return root


def dump_tree(root):
    if root is None:
        return []
    out, queue = [], [root]
    while queue:
        node = queue.pop(0)
        if node is None:
            out.append(None)
            continue
        out.append(node.val)
        queue.append(node.left)
        queue.append(node.right)
    while out and out[-1] is None:       # trim trailing nulls, as LeetCode does
        out.pop()
    return out


class Unsupported(Exception):
    """Raised when a problem cannot be faithfully reproduced locally."""


def extract_prelude(src):
    """Pull helper class definitions out of a leading docstring.

    Problems with custom node types (Node, Interval, ...) declare them in a
    triple-quoted block at the top of the starter and reference solutions.
    We exec that block so annotations naming those types resolve.
    """
    stripped = src.lstrip()
    for quote in ('"' * 3, "'" * 3):
        if stripped.startswith(quote):
            end = stripped.find(quote, len(quote))
            if end == -1:
                return ""
            lines = stripped[len(quote):end].split("\n")
            # Drop prose ("Definition of Interval:") and comment markers that
            # precede the first real class statement.
            start = None
            for i, line in enumerate(lines):
                if line.lstrip("# ").startswith("class "):
                    start = i
                    break
            if start is None:
                return ""
            out = []
            for line in lines[start:]:
                out.append(line.lstrip("#").lstrip() if line.lstrip().startswith("#") else line)
            return "\n".join(out)
    return ""


def class_is_reconstructable(cls):
    """Can instances be rebuilt from a flat sequence of values?

    Self-referential constructors (a Node holding other Nodes) are encoded by
    index rather than by value, which we cannot reproduce generically.
    """
    try:
        sig = inspect.signature(cls.__init__)
    except (TypeError, ValueError):
        return False
    for name, param in sig.parameters.items():
        if name == "self":
            continue
        ann = param.annotation
        text = ann if isinstance(ann, str) else getattr(ann, "__name__", "")
        if cls.__name__ in str(text):
            return False
    return True


def find_in_tree(root, value):
    queue = [root]
    while queue:
        node = queue.pop(0)
        if node is None:
            continue
        if node.val == value:
            return node
        queue.append(node.left)
        queue.append(node.right)
    return None


def find_in_list(head, value):
    while head is not None:
        if head.val == value:
            return head
        head = head.next
    return None


def base_namespace():
    ns = {
        "__name__": "__solution__",
        "ListNode": ListNode,
        "TreeNode": TreeNode,
        "Node": ListNode,
    }
    for name in dir(typing):
        if not name.startswith("_"):
            ns[name] = getattr(typing, name)
    import collections, heapq, bisect, math, itertools, functools, re, string, random
    from collections import defaultdict, deque, Counter, OrderedDict
    ns.update(
        collections=collections, heapq=heapq, bisect=bisect, math=math,
        itertools=itertools, functools=functools, re=re, string=string,
        random=random, defaultdict=defaultdict, deque=deque, Counter=Counter,
        OrderedDict=OrderedDict, inf=float("inf"),
    )
    return ns


def load_solution(path, label, prelude=None, want="Solution"):
    with open(path, "r") as fh:
        src = fh.read()
    ns = base_namespace()
    # Real print; sys.stdout is redirected during invoke() to capture user logs.
    ns["print"] = print
    if prelude:
        exec(compile(prelude, "<problem types>", "exec"), ns)
    exec(compile(src, label, "exec"), ns)
    if want not in ns:
        raise RuntimeError("no `class %s` found in %s" % (want, label))
    return ns[want], ns


def solution_method(cls):
    """The single public method a Solution class exposes."""
    names = [
        n for n, v in vars(cls).items()
        if callable(v) and not n.startswith("_")
    ]
    if not names:
        raise RuntimeError("class Solution defines no public method")
    return names[0]


def parse_scalar(raw):
    try:
        return json.loads(raw)
    except Exception:
        pass
    try:
        return ast.literal_eval(raw)
    except Exception:
        pass
    # A few NeetCode test cases carry an unbalanced trailing bracket; drop
    # trailing closers until the value parses rather than failing the run.
    trimmed = raw
    for _ in range(3):
        if trimmed and trimmed[-1] in "]}":
            trimmed = trimmed[:-1]
            try:
                return json.loads(trimmed)
            except Exception:
                try:
                    return ast.literal_eval(trimmed)
                except Exception:
                    continue
    # Bit-manipulation problems pass 32-bit values as zero-padded binary
    # strings, which are valid in neither JSON nor Python literal syntax.
    if re.fullmatch(r"[01]{32}", raw):
        return int(raw, 2)
    if re.fullmatch(r"[0-9]+", raw):
        return int(raw.lstrip("0") or "0")
    return raw


def parse_input(block):
    """Parse a `name=value` block into an ordered list of (name, value)."""
    args = []
    for line in block.split("\n"):
        line = line.strip()
        if not line or "=" not in line:
            continue
        name, _, raw = line.partition("=")
        args.append((name.strip(), parse_scalar(raw.strip())))
    return args


def annotation_names(ann):
    """Flatten an annotation into the set of type names it mentions."""
    names = set()
    if ann is inspect.Parameter.empty or ann is None:
        return names
    if isinstance(ann, str):
        # Forward-reference annotations arrive as raw text, e.g. "Optional[Node]".
        names.update(re.findall(r"[A-Za-z_]\w*", ann))
        return names
    if hasattr(ann, "__name__"):
        names.add(ann.__name__)
    # Optional['Node'] carries a ForwardRef rather than the class itself.
    forward = getattr(ann, "__forward_arg__", None)
    if forward:
        names.update(re.findall(r"[A-Za-z_]\w*", forward))
    for arg in typing.get_args(ann):
        names |= annotation_names(arg)
    return names


SKIP_TYPES = ("List", "Optional", "int", "str", "float", "bool", "Union", "Any")


def coerce(value, ann, ns=None, built=None):
    names = annotation_names(ann)
    built = built or []

    for kind, builder, finder in (
        ("ListNode", build_list, find_in_list),
        ("TreeNode", build_tree, find_in_tree),
    ):
        if kind not in names:
            continue
        # List[Optional[ListNode]] — a collection of structures, not one.
        if "List" in names and isinstance(value, list):
            return [builder(item) for item in value]
        # A scalar where a node is expected identifies an existing node by
        # value (lowestCommonAncestor's p and q, for example).
        if isinstance(value, (int, float, str)):
            for prior in built:
                found = finder(prior, value)
                if found is not None:
                    return found
            return builder(value if isinstance(value, list) else [])
        return builder(value)

    # A custom problem type (Interval, ...) declared in the prelude.
    for name in names:
        cls = (ns or {}).get(name)
        if isinstance(cls, type) and name not in SKIP_TYPES:
            if not class_is_reconstructable(cls):
                raise Unsupported(
                    "this problem encodes `%s` values by reference, which cannot be "
                    "rebuilt locally" % name)
            is_collection = "List" in names or "Sequence" in names
            try:
                if is_collection and isinstance(value, (list, tuple)):
                    # List[Interval] and friends: one object per element.
                    return [cls(*item) if isinstance(item, (list, tuple)) else cls(item)
                            for item in value]
                if isinstance(value, (list, tuple)) and all(
                        not isinstance(item, (list, tuple)) for item in value):
                    # A single object built from a flat row of constructor args.
                    return cls(*value)
            except TypeError:
                raise Unsupported(
                    "this problem encodes `%s` values in a form that cannot be "
                    "rebuilt locally" % name)
            # A single object described by nested data (an adjacency list, say)
            # is encoded by index, and we cannot reconstruct the links.
            raise Unsupported(
                "this problem encodes `%s` values by reference, which cannot be "
                "rebuilt locally" % name)
    return value


def normalize(value):
    """Convert a return value into plain JSON-able data."""
    if isinstance(value, ListNode):
        return dump_list(value)
    if isinstance(value, TreeNode):
        return dump_tree(value)
    if isinstance(value, (set, frozenset)):
        return sorted(normalize(v) for v in value)
    if isinstance(value, tuple):
        return [normalize(v) for v in value]
    if isinstance(value, list):
        return [normalize(v) for v in value]
    if isinstance(value, dict):
        return {str(k): normalize(v) for k, v in value.items()}
    if hasattr(value, "__dict__") and not isinstance(value, type):
        return {k: normalize(v) for k, v in sorted(vars(value).items())}
    return value


def canonical(value):
    """Order-insensitive form, used only to explain a near-miss."""
    if isinstance(value, list):
        try:
            return sorted((canonical(v) for v in value), key=lambda x: json.dumps(x, sort_keys=True))
        except Exception:
            return [canonical(v) for v in value]
    return value


def fmt(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=False)


def invoke(cls, method, args, params, ret_ann=None, ns=None):
    """Call the solution, returning (output, captured_stdout)."""
    # Bind positionally rather than by name: NeetCode's reference solutions
    # sometimes name a parameter differently from the test-case input (e.g.
    # `S` vs `s`), and inputs are always given in signature order.
    ordered = list(params.values())
    call_args = []
    for i, (_, value) in enumerate(args):
        if i >= len(ordered):
            break
        call_args.append(
            coerce(copy.deepcopy(value), ordered[i].annotation, ns, call_args))

    buf = io.StringIO()
    real_stdout = sys.stdout
    sys.stdout = buf
    try:
        instance = cls()
        result = getattr(instance, method)(*call_args)
    finally:
        sys.stdout = real_stdout

    if result is None:
        ret_names = annotation_names(ret_ann)
        if ret_names & {"ListNode", "TreeNode"}:
            # An empty list/tree is a legitimate answer; render it as [] the way
            # NeetCode does rather than as null.
            return [], buf.getvalue()
        if call_args:
            # In-place problems (Move Zeroes, Merge Sorted Array, ...) return
            # None and mutate their first argument instead.
            result = call_args[0]
    return normalize(result), buf.getvalue()


def retype(value, ann):
    """Line a raw JSON value up with a declared parameter type.

    Some test cases quote their numbers ("1" rather than 1), which would
    otherwise reach an `int` parameter as a string.
    """
    names = annotation_names(ann)
    if isinstance(value, str):
        if "int" in names:
            try:
                return int(value)
            except ValueError:
                pass
        if "float" in names:
            try:
                return float(value)
            except ValueError:
                pass
    elif isinstance(value, (int, float)) and not isinstance(value, bool) and "str" in names:
        return str(value)
    return value


def annotations_for(cls):
    """Parameter annotations for the constructor and every public method."""
    out = {}
    for name in ["__init__"] + [n for n in dir(cls) if not n.startswith("_")]:
        member = getattr(cls, name, None)
        if not callable(member):
            continue
        try:
            params = inspect.signature(member).parameters
        except (TypeError, ValueError):
            continue
        out[name] = [p.annotation for n, p in params.items() if n != "self"]
    return out


def replay(cls, ops, anns):
    """Run one operation sequence against `cls`, collecting every return value.

    The constructor contributes a null, matching how NeetCode reports these.
    `anns` always comes from the reference class, so both implementations are
    handed identically typed arguments.
    """
    def bind(key, args):
        declared = anns.get(key) or []
        return [retype(copy.deepcopy(a), declared[i] if i < len(declared) else None)
                for i, a in enumerate(args)]

    obj = cls(*bind("__init__", ops[0][1:]))
    out = [None]
    for op in ops[1:]:
        method = getattr(obj, op[0], None)
        if method is None:
            raise RuntimeError("your %s has no method named `%s`"
                               % (cls.__name__, op[0]))
        out.append(normalize(method(*bind(op[0], op[1:]))))
    return out


def run_class_cases(workdir, report):
    """Design problems: replay the same calls against both implementations."""
    with open(os.path.join(workdir, "ops.json")) as fh:
        cases = json.load(fh)
    with open(os.path.join(workdir, "cases.json")) as fh:
        raw_cases = json.load(fh)

    name = cases[0][0][0]
    with open(os.path.join(workdir, "ref.py")) as fh:
        prelude = extract_prelude(fh.read())
    UserClass, _ = load_solution(
        os.path.join(workdir, "user.py"), "<your solution>", prelude, name)
    RefClass, _ = load_solution(
        os.path.join(workdir, "ref.py"), "<reference>", prelude, name)
    report["method"] = name
    anns = annotations_for(RefClass)

    for i, ops in enumerate(cases):
        entry = {"index": i, "input": raw_cases[i] if i < len(raw_cases) else ""}

        try:
            expected = replay(RefClass, ops, anns)
            entry["expected"] = fmt(expected)
        except Exception:
            entry["status"] = "oracle_error"
            entry["error"] = traceback.format_exc(limit=3)
            report["cases"].append(entry)
            continue

        buf = io.StringIO()
        real_stdout = sys.stdout
        sys.stdout = buf
        started = time.perf_counter()
        try:
            actual = replay(UserClass, ops, anns)
        except Exception:
            sys.stdout = real_stdout
            entry["status"] = "error"
            entry["elapsed_ms"] = (time.perf_counter() - started) * 1000
            entry["error"] = traceback.format_exc(limit=6)
            report["cases"].append(entry)
            continue
        finally:
            sys.stdout = real_stdout

        entry["elapsed_ms"] = (time.perf_counter() - started) * 1000
        entry["actual"] = fmt(actual)
        if buf.getvalue():
            entry["stdout"] = buf.getvalue()
        entry["status"] = "pass" if actual == expected else "fail"
        report["cases"].append(entry)


def public_methods(cls):
    """Public methods in declaration order (class bodies keep insertion order)."""
    return [n for n, v in vars(cls).items() if callable(v) and not n.startswith("_")]


def run_roundtrip_cases(workdir, report):
    """Encode/decode pairs: push the input through both halves and compare."""
    with open(os.path.join(workdir, "cases.json")) as fh:
        cases = json.load(fh)
    with open(os.path.join(workdir, "ref.py")) as fh:
        ref_src = fh.read()

    found = re.findall(r"^class\s+(\w+)", ref_src, re.M)
    if not found:
        raise Unsupported("could not find the class in the reference solution")
    name = found[-1]

    prelude = extract_prelude(ref_src)
    UserClass, user_ns = load_solution(
        os.path.join(workdir, "user.py"), "<your solution>", prelude, name)
    RefClass, ref_ns = load_solution(
        os.path.join(workdir, "ref.py"), "<reference>", prelude, name)

    methods = public_methods(RefClass)
    if len(methods) < 2:
        raise Unsupported("expected an encode/decode pair on `%s`" % name)
    encode, decode = methods[0], methods[1]
    report["method"] = "%s -> %s" % (encode, decode)

    params = [
        p for n, p in inspect.signature(getattr(RefClass, encode)).parameters.items()
        if n != "self"
    ]

    def roundtrip(cls, ns, args):
        obj = cls()
        call = []
        for i, (_, value) in enumerate(args):
            ann = params[i].annotation if i < len(params) else None
            call.append(coerce(copy.deepcopy(value), ann, ns, call))
        return normalize(getattr(obj, decode)(getattr(obj, encode)(*call)))

    for i, block in enumerate(cases):
        args = parse_input(block)
        entry = {"index": i, "input": block}

        try:
            expected = roundtrip(RefClass, ref_ns, args)
            entry["expected"] = fmt(expected)
        except Unsupported:
            raise
        except Exception:
            entry["status"] = "oracle_error"
            entry["error"] = traceback.format_exc(limit=3)
            report["cases"].append(entry)
            continue

        buf = io.StringIO()
        real_stdout = sys.stdout
        sys.stdout = buf
        started = time.perf_counter()
        try:
            actual = roundtrip(UserClass, user_ns, args)
        except Exception:
            sys.stdout = real_stdout
            entry["status"] = "error"
            entry["elapsed_ms"] = (time.perf_counter() - started) * 1000
            entry["error"] = traceback.format_exc(limit=6)
            report["cases"].append(entry)
            continue
        finally:
            sys.stdout = real_stdout

        entry["elapsed_ms"] = (time.perf_counter() - started) * 1000
        entry["actual"] = fmt(actual)
        if buf.getvalue():
            entry["stdout"] = buf.getvalue()
        entry["status"] = "pass" if actual == expected else "fail"
        report["cases"].append(entry)


def main():
    workdir = sys.argv[1]
    mode = sys.argv[2] if len(sys.argv) > 2 else "function"
    report = {"ok": True, "cases": []}

    if mode in ("class", "roundtrip"):
        runner = run_class_cases if mode == "class" else run_roundtrip_cases
        try:
            runner(workdir, report)
        except Unsupported as exc:
            report.update(ok=False, unsupported=True, error=str(exc))
        except Exception:
            report.update(ok=False, error=traceback.format_exc(limit=3))
        print(json.dumps(report))
        return

    with open(os.path.join(workdir, "cases.json")) as fh:
        cases = json.load(fh)

    try:
        with open(os.path.join(workdir, "ref.py")) as fh:
            prelude = extract_prelude(fh.read())
        UserSolution, user_ns = load_solution(
            os.path.join(workdir, "user.py"), "<your solution>", prelude)
        RefSolution, ref_ns = load_solution(
            os.path.join(workdir, "ref.py"), "<reference>", prelude)
        method = solution_method(RefSolution)
        if not hasattr(UserSolution, method):
            raise RuntimeError(
                "your Solution class has no method named `%s`" % method)
        signature = inspect.signature(getattr(RefSolution, method))
        ret_ann = signature.return_annotation
        params = {k: v for k, v in signature.parameters.items() if k != "self"}
    except Unsupported as exc:
        report["ok"] = False
        report["unsupported"] = True
        report["error"] = str(exc)
        print(json.dumps(report))
        return
    except Exception:
        report["ok"] = False
        report["error"] = traceback.format_exc(limit=3)
        print(json.dumps(report))
        return

    report["method"] = method

    for i, block in enumerate(cases):
        args = parse_input(block)
        entry = {"index": i, "input": block}

        try:
            expected, _ = invoke(RefSolution, method, args, params, ret_ann, ref_ns)
            entry["expected"] = fmt(expected)
        except Unsupported as exc:
            report["ok"] = False
            report["unsupported"] = True
            report["error"] = str(exc)
            print(json.dumps(report))
            return
        except Exception:
            entry["status"] = "oracle_error"
            entry["error"] = traceback.format_exc(limit=3)
            report["cases"].append(entry)
            continue

        started = time.perf_counter()
        try:
            actual, logs = invoke(UserSolution, method, args, params, ret_ann, user_ns)
        except Exception:
            entry["status"] = "error"
            entry["elapsed_ms"] = (time.perf_counter() - started) * 1000
            entry["error"] = traceback.format_exc(limit=6)
            report["cases"].append(entry)
            continue

        entry["elapsed_ms"] = (time.perf_counter() - started) * 1000
        entry["actual"] = fmt(actual)
        if logs:
            entry["stdout"] = logs

        if actual == expected:
            entry["status"] = "pass"
        elif canonical(actual) == canonical(expected):
            # Many problems accept any ordering; the real judge decides, so we
            # surface this as a pass but say the ordering differed.
            entry["status"] = "pass_unordered"
        else:
            entry["status"] = "fail"

        report["cases"].append(entry)

    print(json.dumps(report))


if __name__ == "__main__":
    main()
