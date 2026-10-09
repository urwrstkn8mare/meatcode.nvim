"""Local test harness for meatcode.nvim (Python).

Two oracles produce the answers a case is judged against:

- "reference": the harness runs a provider's solution (NeetCode reference,
  editorial or community code being validated) over the same input and diffs
  the two results. Judges any input, including cases you wrote yourself.
- "expected": the runner's answer cache (judge answers, statement answers, the
  selected oracle's outputs) arrives in expected.json, aligned with
  cases.json: every acceptable answer per case, since a problem may accept
  several. A case with no known answer still runs, and reports its output
  unjudged.

Both the user solution and the signature source run in isolated namespaces
seeded with the type names their annotations expect (List, Optional, ListNode,
TreeNode, ...) plus helper definitions discovered in starter.py (the provider's
starter code, including any documented type blocks) that the solution file does
not declare itself.

Custom record types decode from positional arrays or named-field objects, with
constructor defaults for missing optional fields; reference-capable types also
decode explicit identity objects ({"$id": ...} definitions, {"$ref": ...}
references, per case) with forward references, sharing and cycles. Returns
serialize positionally, or as id/ref objects when the graph carries identity.

Usage: python3 python.py <workdir> [mode] [oracle]
Reads user.py, ref.py, starter.py, cases.json and (for the expected oracle)
expected.json from <workdir>; writes a JSON report to stdout.
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
import linecache
import textwrap
import types
import collections.abc
import dataclasses


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
                out.append(re.sub(r"^\s*# ?", "", line) if line.lstrip().startswith("#") else line)
            return "\n".join(out)
    return ""




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
    ns.update(dataclass=dataclasses.dataclass, dataclasses=dataclasses)
    return ns

def _definition_source(src, node):
    start = min([node.lineno] + [decorator.lineno for decorator in node.decorator_list])
    return "".join(src.splitlines(True)[start - 1:node.end_lineno])



def _documented_defs(src):
    """Recover helper classes from docstrings and commented declaration blocks."""
    blocks = [extract_prelude(src)]
    comments = []
    for line in src.splitlines() + [""]:
        match = re.match(r"^\s*# ?(.*)$", line)
        if match:
            comments.append(match.group(1))
        elif comments:
            blocks.append("\n".join(comments))
            comments = []
    definitions = []
    for block in blocks:
        lines = textwrap.dedent(block).splitlines()
        start = next((i for i, line in enumerate(lines)
                      if line.startswith("class ") or line.startswith("@dataclass")), None)
        if start is None:
            continue
        declaration = "\n".join(lines[start:])
        try:
            tree = ast.parse(declaration)
        except SyntaxError:
            continue
        definitions.extend(
            (node.name, _definition_source(declaration, node))
            for node in tree.body if isinstance(node, ast.ClassDef)
        )
    return definitions


def _actual_defs(src):
    """Top-level helper code in a solution/starter file (its Solution excluded)."""
    try:
        src = repair(src)
        tree = ast.parse(src)
    except (SyntaxError, ValueError, RecursionError):
        return []
    return [
        (node.name, _definition_source(src, node))
        for node in tree.body
        if isinstance(node, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef))
        and node.name != "Solution"
    ]


def solution_prelude(workdir, target):
    """Definitions to seed one solution namespace before its own code runs.

    `target` is "user.py" or "ref.py". Documented definitions (leading
    docstring/comment blocks of the starter and both solution files) are
    injected, plus helper code the starter itself declares, unless the target
    file actually declares that helper. Actual user/reference declarations
    stay inside their own files, so user and reference namespaces remain
    independent and nothing is ever injected back into a user file.
    """
    sources = {}
    for name in ("user.py", "ref.py", "starter.py"):
        path = os.path.join(workdir, name)
        if os.path.exists(path):
            with open(path) as fh:
                sources[name] = fh.read()
    target_src = sources.get(target, "")
    other_src = sources.get("ref.py" if target == "user.py" else "user.py", "")
    starter_src = sources.get("starter.py", "")
    parts, seen = [], {name for name, _ in _actual_defs(target_src)}
    documented = (
        _documented_defs(starter_src)
        + _documented_defs(target_src)
        + _documented_defs(other_src)
    )
    for name, segment in _actual_defs(starter_src) + documented:
        if name in seen:
            continue
        seen.add(name)
        parts.append(segment)
    return "\n\n".join(parts)


def load_solution(path, label, prelude=None, want="Solution"):
    with open(path, "r") as fh:
        src = repair(fh.read())
    ns = base_namespace()
    # Real print; sys.stdout is redirected during invoke() to capture user logs.
    ns["print"] = print
    if prelude:
        prelude_label = label + " types"
        linecache.cache[prelude_label] = (len(prelude), None, prelude.splitlines(True), prelude_label)
        exec(compile(prelude, prelude_label, "exec"), ns)
    linecache.cache[label] = (len(src), None, src.splitlines(True), label)
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


def _pythonize_json_words(raw):
    """Rewrite JSON null/true/false to Python None/True/False outside quotes.

    NeetCode tuple rows mix Python parentheses with JSON keywords
    (`(5,null)`, `(true,false)`). json.loads rejects the parentheses and
    ast.literal_eval rejects the keywords, so translate only bare words.
    """
    out = []
    i = 0
    n = len(raw)
    quote = None
    escaped = False
    words = (("null", "None"), ("true", "True"), ("false", "False"))
    while i < n:
        c = raw[i]
        if quote:
            out.append(c)
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == quote:
                quote = None
            i += 1
            continue
        if c in "\"'":
            quote = c
            out.append(c)
            i += 1
            continue
        replaced = False
        for word, repl in words:
            end = i + len(word)
            if not raw.startswith(word, i):
                continue
            before = raw[i - 1] if i else ""
            after = raw[end] if end < n else ""
            if (before.isalnum() or before == "_") or (after.isalnum() or after == "_"):
                continue
            out.append(repl)
            i = end
            replaced = True
            break
        if replaced:
            continue
        out.append(c)
        i += 1
    return "".join(out)


def _literal_eval(raw):
    candidates = [raw]
    rewritten = _pythonize_json_words(raw)
    if rewritten != raw:
        candidates.append(rewritten)
    for candidate in candidates:
        try:
            return True, ast.literal_eval(candidate)
        except Exception:
            continue
    return False, None


def parse_scalar(raw):
    try:
        return json.loads(raw)
    except Exception:
        pass
    ok, value = _literal_eval(raw)
    if ok:
        return value
    # A few NeetCode test cases carry an unbalanced trailing bracket; drop
    # trailing closers until the value parses rather than failing the run.
    trimmed = raw
    for _ in range(3):
        if trimmed and trimmed[-1] in "]}":
            trimmed = trimmed[:-1]
            try:
                return json.loads(trimmed)
            except Exception:
                ok, value = _literal_eval(trimmed)
                if ok:
                    return value
                continue
    # Bit-manipulation problems pass 32-bit values as zero-padded binary
    # strings, which are valid in neither JSON nor Python literal syntax.
    if re.fullmatch(r"[01]{32}", raw):
        return int(raw, 2)
    if re.fullmatch(r"[0-9]+", raw):
        return int(raw.lstrip("0") or "0")
    return raw


def parse_input(block):
    """Parse an input block into an ordered list of (name, value).

    NeetCode labels every value (`nums=[1,2]`). LeetCode and LintCode hand out
    bare values, one per line, in signature order; those bind positionally, so
    they are returned with an empty name.
    """
    args = []
    for line in block.split("\n"):
        line = line.strip()
        if not line:
            continue
        name, sep, raw = line.partition("=")
        if sep and re.fullmatch(r"[A-Za-z_]\w*", name.strip()):
            args.append((name.strip(), parse_scalar(raw.strip())))
        else:
            args.append(("", parse_scalar(line)))
    return args


def repair(src):
    """Make starter code importable.

    LeetCode and LintCode ship starters whose method body is a comment or
    nothing at all, which does not parse. The starter is never executed under
    the expected-output oracle — it is only there to carry the signature — so an
    empty body is filled in with `pass`.
    """
    try:
        ast.parse(src)
        return src
    except SyntaxError:
        pass
    lines = src.split("\n")
    out = []
    for i, line in enumerate(lines):
        out.append(line)
        stripped = line.strip()
        if not stripped.endswith(":") or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        body = None
        for nxt in lines[i + 1:]:
            if nxt.strip() and not nxt.strip().startswith("#"):
                body = nxt
                break
        if body is None or (len(body) - len(body.lstrip())) <= indent:
            out.append(" " * (indent + 4) + "pass")
    repaired = "\n".join(out)
    ast.parse(repaired)
    return repaired


def load_types(workdir):
    """Parameter types the provider declares, positionally.

    Starter code normally annotates itself, but the encode/decode starters do
    not — an unannotated `root` would reach the solution as a plain list rather
    than a tree. These names fill that gap; `annotation_names` reads them the
    same way it reads a forward reference.
    """
    path = os.path.join(workdir, "types.json")
    if not os.path.exists(path):
        return []
    with open(path) as fh:
        raw = json.load(fh)
    return [t if isinstance(t, str) else None for t in raw]


def annotation_at(params, declared, i):
    """The annotation for argument `i`, falling back to the declared type."""
    ann = params[i].annotation if i < len(params) else inspect.Parameter.empty
    if ann is inspect.Parameter.empty and i < len(declared) and declared[i]:
        return declared[i]
    return ann


def load_expected(workdir, count):
    """Known answers per case: a list of acceptable values (empty when none
    are usable).

    Each element of `expected.json` is `null` or a list of JSON- or
    Python-literal-encoded strings; every string that parses successfully
    becomes one acceptable answer. A case left with an empty list (no
    element, `null`, `[]`, or every string failing to parse — an answer
    written as prose) grades as `no_oracle`.
    """
    path = os.path.join(workdir, "expected.json")
    if not os.path.exists(path):
        return [[] for _ in range(count)]
    with open(path) as fh:
        raw = json.load(fh)
    out = []
    for i in range(count):
        value = raw[i] if i < len(raw) else None
        answers = []
        if isinstance(value, list):
            for item in value:
                if not isinstance(item, str) or not item.strip():
                    continue
                try:
                    answers.append(normalize(json.loads(item)))
                    continue
                except Exception:
                    pass
                try:
                    answers.append(normalize(ast.literal_eval(item)))
                except Exception:
                    # Statements sometimes annotate the answer in prose
                    # ("5, nums = [0,1,_,_]"); that cannot be judged against.
                    pass
        out.append(answers)
    return out


def judge(entry, actual, answers):
    """Grade one case against a list of acceptable answers.

    An empty `answers` list means no usable answer is known for this case.
    Otherwise an exact match to any answer is a `pass`; failing that,
    an order-insensitive (`canonical`) match to any answer is a
    `pass_unordered`; otherwise `fail`, reported against the first answer.
    """
    if not answers:
        entry["status"] = "no_oracle"
        return
    entry["expected"] = fmt(answers[0])
    for ans in answers:
        if actual == ans:
            entry["expected"] = fmt(ans)
            entry["status"] = "pass"
            return
    actual_canon = canonical(actual)
    for ans in answers:
        if actual_canon == canonical(ans):
            entry["expected"] = fmt(ans)
            entry["status"] = "pass_unordered"
            return
    entry["status"] = "fail"


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
    forward = getattr(ann, "__forward_arg__", None)
    if forward:
        names.update(re.findall(r"[A-Za-z_]\w*", str(forward)))
    for arg in typing.get_args(ann):
        names |= annotation_names(arg)
    return names


def resolved(ann, ns):
    if not isinstance(ann, str) and not isinstance(ann, typing.ForwardRef):
        return ann
    seen = set()
    while isinstance(ann, (str, typing.ForwardRef)):
        expression = ann if isinstance(ann, str) else ann.__forward_arg__
        if expression in seen:
            raise Unsupported("unsupported recursive annotation `%s`" % expression)
        seen.add(expression)
        try:
            ann = eval(expression, ns)
        except Exception:
            raise Unsupported("unsupported unresolved annotation `%s`" % expression)
    return ann


def _origin(ann):
    return typing.get_origin(ann), typing.get_args(ann)


def _field_map(cls, params):
    """Map constructor parameters to stored attributes without guessing invariants."""
    if cls.__init__ is object.__init__:
        return {}
    if (dataclasses.is_dataclass(cls)
            and getattr(getattr(cls.__init__, "__code__", None), "co_filename", None) == "<string>"):
        declared = dataclasses.fields(cls)
        if (hasattr(cls, "__post_init__")
                or any(not field.init or field.default_factory is not dataclasses.MISSING
                       for field in declared)):
            return None
        fields = {field.name for field in declared}
        return {p.name: p.name for p in params} if fields == {p.name for p in params} else None
    try:
        tree = ast.parse(textwrap.dedent(inspect.getsource(cls.__init__)))
    except (OSError, TypeError, SyntaxError, IndentationError):
        return None
    functions = [node for node in tree.body if isinstance(node, ast.FunctionDef)]
    if len(functions) != 1:
        return None
    names, mapping, stored = {p.name for p in params}, {}, set()
    for statement in functions[0].body:
        if isinstance(statement, ast.Pass):
            continue
        if (isinstance(statement, ast.Expr) and isinstance(statement.value, ast.Constant)
                and isinstance(statement.value.value, str)):
            continue
        if isinstance(statement, ast.Assign) and len(statement.targets) == 1:
            target, value = statement.targets[0], statement.value
        elif isinstance(statement, ast.AnnAssign):
            target, value = statement.target, statement.value
        else:
            return None
        if not (isinstance(target, ast.Attribute) and isinstance(target.value, ast.Name)
                and target.value.id == "self" and isinstance(value, ast.Name)
                and value.id in names and value.id not in mapping and target.attr not in stored):
            return None
        mapping[value.id] = target.attr
        stored.add(target.attr)
    return mapping if set(mapping) == names else None


def _fields(cls, ns):
    if cls.__init__ is object.__init__:
        if getattr(cls, "__annotations__", {}):
            raise Unsupported("constructor for `%s` does not initialize its declared fields" % cls.__name__)
        return [], {}, {}
    try:
        sig = inspect.signature(cls.__init__)
    except (TypeError, ValueError):
        raise Unsupported("cannot inspect constructor for `%s`" % cls.__name__)
    params = [p for name, p in sig.parameters.items() if name != "self"]
    if any(p.kind not in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD, p.KEYWORD_ONLY)
           for p in params):
        raise Unsupported("unsupported variadic constructor for `%s`" % cls.__name__)
    mapping = _field_map(cls, params)
    if mapping is None:
        raise Unsupported("constructor for `%s` cannot be mapped to plain stored fields" % cls.__name__)
    try:
        hints = typing.get_type_hints(cls.__init__, globalns=ns, localns=ns)
    except Exception:
        hints = {}
    try:
        field_hints = typing.get_type_hints(cls, globalns=ns, localns=ns)
    except Exception:
        field_hints = getattr(cls, "__annotations__", {})
    for param in params:
        if param.name not in hints and param.annotation is inspect.Parameter.empty:
            hints[param.name] = field_hints.get(mapping[param.name], inspect.Parameter.empty)
    return params, hints, mapping

def _construct(cls, params, values):
    positional, keywords = [], {}
    for param, value in zip(params, values):
        if param.kind == param.KEYWORD_ONLY:
            keywords[param.name] = value
        else:
            positional.append(value)
    return cls(*positional, **keywords)



def _safe_shell_constructor(cls, mapping):
    """Shell assignment is faithful only for ordinary mutable record attributes."""
    if (cls.__new__ is not object.__new__
            or cls.__setattr__ is not object.__setattr__
            or cls.__getattribute__ is not object.__getattribute__):
        return False
    for field in mapping.values():
        attr = inspect.getattr_static(cls, field, None)
        if (attr is not None and hasattr(attr, "__set__")
                and not isinstance(attr, types.MemberDescriptorType)):
            return False
    return True


def _reference_capable(cls, ns):
    # Python user-defined classes have reference semantics even when every
    # stored field is scalar. Collections of the same instance retain aliases.
    return isinstance(cls, type) and cls not in (
        int, float, bool, str, bytes, complex, list, tuple, dict, set, frozenset,
        type(None), ListNode, TreeNode,
    )

class Codec:
    """One invocation's typed decoder and identity table."""
    def __init__(self, ns):
        self.ns = ns or {}
        self.defs = {}
        self.objects = {}
        self.output_ids = {}
        self.next_output_id = 1
        self.graph_counts = None
        self.schemas = {}

    def _schema(self, cls):
        if cls not in self.schemas:
            self.schemas[cls] = _fields(cls, getattr(cls.__init__, "__globals__", self.ns))
        return self.schemas[cls]

    def _count_graph(self, value, counts, active):
        if isinstance(value, (list, tuple)):
            for item in value:
                self._count_graph(item, counts, active)
        elif isinstance(value, dict):
            for key in sorted(value, key=str):
                self._count_graph(value[key], counts, active)
        elif _reference_capable(type(value), self.ns) and not isinstance(value, type):
            oid = id(value)
            counts[oid] = counts.get(oid, 0) + 1
            if oid in active or counts[oid] > 1:
                return
            active.add(oid)
            for _, item in self._record_items(value):
                self._count_graph(item, counts, active)
            active.remove(oid)

    def _scan(self, value):
        if isinstance(value, dict):
            if "$ref" in value:
                if len(value) != 1:
                    raise ValueError("reference object must contain only $ref")
            elif "$id" in value:
                ident = value["$id"]
                if not isinstance(ident, (str, int)) or isinstance(ident, bool) or ident == "":
                    raise ValueError("$id must be a nonempty string or integer")
                if ident in self.defs:
                    raise ValueError("duplicate identity %r" % ident)
                self.defs[ident] = value
            for child in value.values():
                self._scan(child)
        elif isinstance(value, (list, tuple)):
            for child in value:
                self._scan(child)

    def prepare(self, values):
        for value in values:
            self._scan(value)

    def decode(self, value, ann, prior=()):
        ann = resolved(ann, self.ns)
        if isinstance(ann, type) and ann not in (int, float, bool, str, list, tuple, dict):
            local = self.ns.get(ann.__name__)
            if isinstance(local, type):
                ann = local
        if ann is inspect.Parameter.empty or ann is typing.Any:
            if isinstance(value, dict) and ("$id" in value or "$ref" in value):
                raise Unsupported("identity tags require an annotated reference-capable type")
            return value
        origin, args = _origin(ann)
        if origin in (typing.Union, getattr(types, "UnionType", object)):
            choices = [a for a in args if a is not type(None)]
            if value is None:
                if type(None) not in args:
                    raise TypeError("null supplied for non-optional type %s" % ann)
                return None
            if len(choices) != 1:
                raise Unsupported("ambiguous union annotation `%s`" % ann)
            return self.decode(value, choices[0], prior)
        if value is None:
            if ann in (ListNode, TreeNode, type(None), None):
                return None
            raise TypeError("null supplied for non-optional type %s" % ann)
        if origin in (list, typing.List, typing.Sequence, typing.MutableSequence,
                      collections.abc.Sequence, collections.abc.MutableSequence):
            if not isinstance(value, list):
                raise TypeError("expected array for %s" % ann)
            item = args[0] if args else typing.Any
            return [self.decode(v, item, prior) for v in value]
        if origin in (dict, typing.Dict, typing.Mapping, typing.MutableMapping,
                      collections.abc.Mapping, collections.abc.MutableMapping):
            if not isinstance(value, dict) or "$id" in value or "$ref" in value:
                raise TypeError("expected string-keyed object for %s" % ann)
            key, item = args if len(args) == 2 else (str, typing.Any)
            if key is not str:
                raise Unsupported("only string-keyed maps are supported")
            return {k: self.decode(v, item, prior) for k, v in value.items()}
        if origin in (tuple, typing.Tuple):
            if not isinstance(value, (list, tuple)):
                raise TypeError("expected array for %s" % ann)
            if len(args) == 2 and args[1] is Ellipsis:
                return tuple(self.decode(v, args[0], prior) for v in value)
            if len(value) != len(args):
                raise TypeError("tuple expects %d values, got %d" % (len(args), len(value)))
            return tuple(self.decode(v, t, prior) for v, t in zip(value, args))
        if ann in (int, float, str, bool):
            value = retype(value, ann)
            if ann is float and isinstance(value, int) and not isinstance(value, bool):
                value = float(value)
            if not isinstance(value, ann) or (ann is int and isinstance(value, bool)):
                raise TypeError("expected %s, got %s" % (ann.__name__, type(value).__name__))
            return value
        if ann in (list, tuple, dict):
            if not isinstance(value, ann):
                raise TypeError("expected %s for untyped container" % ann.__name__)
            return value
        if ann in (ListNode, TreeNode):
            if isinstance(value, dict):
                raise Unsupported("identity encoding for built-in ListNode/TreeNode is unsupported")
            if isinstance(value, (int, float, str)):
                # A scalar where a node is expected identifies an existing
                # node by value (lowestCommonAncestor's p and q, for example).
                for earlier in prior:
                    found = (find_in_tree(earlier, value) if ann is TreeNode
                             else find_in_list(earlier, value))
                    if found is not None:
                        return found
                return build_list([]) if ann is ListNode else build_tree([])
            return build_list(value) if ann is ListNode else build_tree(value)
        if isinstance(ann, type):
            if not isinstance(value, (dict, list, tuple)):
                raise TypeError("expected named object or positional array for %s" % ann.__name__)
            params, hints, mapping = self._schema(ann)
            names = list(mapping.values())
            identity = isinstance(value, dict) and ("$id" in value or "$ref" in value)
            if identity:
                if not _reference_capable(ann, self.ns):
                    raise ValueError(
                        "identity tags are invalid for value-only type %s" % ann.__name__)
                if not _safe_shell_constructor(ann, mapping):
                    raise Unsupported(
                        "`%s` carries identity, which the harness may only rebuild from a "
                        "plain field-assigning __init__" % ann.__name__)
                if "$ref" in value:
                    if set(value) != {"$ref"}:
                        raise ValueError("reference object must contain only $ref")
                    ident = value["$ref"]
                    if ident not in self.defs:
                        raise ValueError("unresolved reference %r" % ident)
                    obj = self.objects.get(ident)
                    if obj is None:
                        self.objects[ident] = obj = ann.__new__(ann)
                        self._fill_record(obj, self.defs[ident], ann, params, hints, mapping, prior)
                    elif not isinstance(obj, ann):
                        raise ValueError("reference %r has wrong type (expected %s)"
                                         % (ident, ann.__name__))
                    return obj
                ident = value["$id"]
                if (not isinstance(ident, (str, int)) or isinstance(ident, bool)
                        or ident == ""):
                    raise ValueError("$id must be a nonempty string or integer")
                if ident in self.objects:
                    obj = self.objects[ident]
                    if not isinstance(obj, ann):
                        raise ValueError("identity %r has wrong type" % ident)
                    return obj
                self.objects[ident] = obj = ann.__new__(ann)
                self._fill_record(obj, value, ann, params, hints, mapping, prior)
                return obj
            if isinstance(value, dict):
                data = {k: v for k, v in value.items() if k != "$id"}
                unknown = set(data) - set(names)
                if unknown:
                    raise TypeError("unknown fields for %s: %s" % (ann.__name__, sorted(unknown)))
                vals = []
                for p in params:
                    if mapping[p.name] in data:
                        vals.append(self.decode(data[mapping[p.name]], hints.get(p.name, p.annotation), prior))
                    elif p.default is not inspect.Parameter.empty:
                        vals.append(p.default)
                    else:
                        raise TypeError("missing required field `%s` for %s"
                                        % (p.name, ann.__name__))
                return _construct(ann, params, vals)
            if len(value) > len(params):
                raise TypeError("%s expects at most %d values, got %d"
                                % (ann.__name__, len(params), len(value)))
            vals = []
            for i, p in enumerate(params):
                if i < len(value):
                    vals.append(self.decode(value[i], hints.get(p.name, p.annotation), prior))
                elif p.default is not inspect.Parameter.empty:
                    vals.append(p.default)
                else:
                    raise TypeError("missing required positional field `%s` for %s"
                                    % (p.name, ann.__name__))
            return _construct(ann, params, vals)
        raise Unsupported("unsupported annotation `%s`" % ann)

    def _fill_record(self, obj, value, cls, params, hints, mapping, prior):
        fields = {k: v for k, v in value.items() if k != "$id"}
        if "$ref" in fields:
            raise ValueError("identity definition cannot also be a reference")
        names = set(mapping.values())
        unknown = set(fields) - names
        if unknown:
            raise TypeError("unknown fields for %s: %s" % (cls.__name__, sorted(unknown)))
        for p in params:
            field = mapping[p.name]
            if field in fields:
                setattr(obj, field, self.decode(fields[field], hints.get(p.name, p.annotation), prior))
            elif p.default is not inspect.Parameter.empty:
                setattr(obj, field, p.default)
            else:
                raise TypeError("missing required field `%s` for %s" % (p.name, cls.__name__))

    def encode(self, value):
        """Serialize a return value, preserving graph identity when needed."""
        self.graph_counts = {}
        self._count_graph(value, self.graph_counts, set())
        self.graph_mode = bool(self.defs) or any(count > 1 for count in self.graph_counts.values())
        return self._emit(value)

    def _emit(self, value):
        if isinstance(value, (ListNode, TreeNode)):
            return dump_list(value) if isinstance(value, ListNode) else dump_tree(value)
        if value is None or isinstance(value, (str, int, float, bool)):
            return value
        if isinstance(value, (list, tuple)):
            return [self._emit(v) for v in value]
        if isinstance(value, dict):
            return {str(k): self._emit(value[k]) for k in sorted(value, key=str)}
        if _reference_capable(type(value), self.ns) and not isinstance(value, type):
            oid = id(value)
            if oid in self.output_ids:
                return {"$ref": self.output_ids[oid][0]}
            if self.graph_mode:
                # Explicit identity or real sharing/cycles: keep id/ref so the
                # graph shape survives; plain acyclic records stay positional.
                ident = self.next_output_id
                self.next_output_id += 1
                self.output_ids[oid] = (ident, value)
                result = {"$id": ident}
                result.update((k, self._emit(v)) for k, v in self._record_items(value))
                return result
            return [self._emit(v) for _, v in self._record_items(value)]
        if isinstance(value, (set, frozenset)):
            return sorted(self._emit(v) for v in value)
        raise Unsupported("cannot serialize object of type %s" % type(value).__name__)

    def _record_items(self, value):
        cls = type(value)
        params, _, mapping = self._schema(cls)
        items = []
        for param in params:
            field = mapping[param.name]
            if not hasattr(value, field):
                raise Unsupported("constructor field `%s` is not stored on %s"
                                  % (field, cls.__name__))
            items.append((field, getattr(value, field)))
        return items




def normalize(value):
    return Codec({}).encode(value)


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


def invoke(cls, method, args, params, ret_ann=None, ns=None, declared=()):
    """Call the solution, returning (output, captured_stdout)."""
    # Bind positionally rather than by name: NeetCode's reference solutions
    # sometimes name a parameter differently from the test-case input (e.g.
    # `S` vs `s`), and inputs are always given in signature order.
    ordered = list(params.values())
    codec = Codec(ns)
    raw_values = [copy.deepcopy(value) for _, value in args[:len(ordered)]]
    codec.prepare(raw_values)
    call_args = []
    for i, value in enumerate(raw_values):
        call_args.append(codec.decode(value, annotation_at(ordered, declared, i), call_args))

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
    return codec.encode(result), buf.getvalue()


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


def replay(cls, ops, anns, ns):
    """Run one operation sequence against `cls`, collecting every return value.

    The constructor contributes a null, matching how NeetCode reports these.
    `anns` always comes from the reference class, so both implementations are
    handed identically typed arguments.
    """
    codec = Codec(ns)
    raw = [arg for op in ops for arg in op[1:]]
    codec.prepare(raw)

    def bind(key, args):
        declared = anns.get(key) or []
        return [codec.decode(copy.deepcopy(arg), declared[i] if i < len(declared) else None)
                for i, arg in enumerate(args)]

    obj = cls(*bind("__init__", ops[0][1:]))
    out = [None]
    for op in ops[1:]:
        method = getattr(obj, op[0], None)
        if method is None:
            raise RuntimeError("your %s has no method named `%s`"
                               % (cls.__name__, op[0]))
        out.append(codec.encode(method(*bind(op[0], op[1:]))))
    return out


def run_class_cases(workdir, report, oracle, shard=0, stride=1):
    """Design problems: replay the recorded call sequence and grade the returns.

    Under the reference oracle the same sequence runs against NeetCode's class
    too; otherwise the published answer list is the expected value. `ref.py` is
    the signature source either way, so annotations resolve the same.
    """
    with open(os.path.join(workdir, "ops.json")) as fh:
        cases = json.load(fh)
    with open(os.path.join(workdir, "cases.json")) as fh:
        raw_cases = json.load(fh)

    name = cases[0][0][0]
    user_prelude = solution_prelude(workdir, "user.py")
    ref_prelude = solution_prelude(workdir, "ref.py")
    UserClass, user_ns = load_solution(
        os.path.join(workdir, "user.py"), "<your solution>", user_prelude, name)
    RefClass, ref_ns = load_solution(
        os.path.join(workdir, "ref.py"), "<reference>", ref_prelude, name)
    report["method"] = name
    anns = annotations_for(RefClass)
    published = load_expected(workdir, len(cases)) if oracle == "expected" else None

    for i, ops in enumerate(cases):
        if i % stride != shard:
            continue
        entry = {"index": i, "input": raw_cases[i] if i < len(raw_cases) else ""}

        if published is not None:
            answers = published[i]
        else:
            try:
                answers = [replay(RefClass, ops, anns, ref_ns)]
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
            actual = replay(UserClass, ops, anns, user_ns)
        except Unsupported:
            raise
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
        judge(entry, actual, answers)
        report["cases"].append(entry)


def public_methods(cls):
    """Public methods in declaration order (class bodies keep insertion order)."""
    return [n for n, v in vars(cls).items() if callable(v) and not n.startswith("_")]


def run_roundtrip_cases(workdir, report, oracle, shard=0, stride=1):
    """Encode/decode pairs: push the input through both halves and compare.

    The pair has to invert itself, so with no reference solution the input is
    its own expected output — no published answer is needed.
    """
    with open(os.path.join(workdir, "cases.json")) as fh:
        cases = json.load(fh)
    with open(os.path.join(workdir, "ref.py")) as fh:
        ref_src = fh.read()

    found = re.findall(r"^class\s+(\w+)", ref_src, re.M)
    if not found:
        raise Unsupported("could not find the class in the reference solution")
    name = found[-1]

    user_prelude = solution_prelude(workdir, "user.py")
    ref_prelude = solution_prelude(workdir, "ref.py")
    UserClass, user_ns = load_solution(
        os.path.join(workdir, "user.py"), "<your solution>", user_prelude, name)
    RefClass, ref_ns = load_solution(
        os.path.join(workdir, "ref.py"), "<reference>", ref_prelude, name)

    methods = public_methods(RefClass)
    if len(methods) < 2:
        raise Unsupported("expected an encode/decode pair on `%s`" % name)
    encode, decode = methods[0], methods[1]
    report["method"] = "%s -> %s" % (encode, decode)

    params = [
        p for n, p in inspect.signature(getattr(RefClass, encode)).parameters.items()
        if n != "self"
    ]

    declared = load_types(workdir)

    def roundtrip(cls, ns, args):
        obj = cls()
        codec = Codec(ns)
        raw_values = [copy.deepcopy(value) for _, value in args[:len(params)]]
        codec.prepare(raw_values)
        call = []
        for i, value in enumerate(raw_values):
            call.append(codec.decode(value, annotation_at(params, declared, i), call))
        result = getattr(obj, decode)(getattr(obj, encode)(*call))
        return codec.encode(result)

    for i, block in enumerate(cases):
        if i % stride != shard:
            continue
        args = parse_input(block)
        entry = {"index": i, "input": block}

        if oracle == "expected":
            answers = []
            if args:
                codec = Codec(user_ns)
                raw = copy.deepcopy(args[0][1])
                codec.prepare([raw])
                answers = [codec.encode(codec.decode(
                    raw, annotation_at(params, declared, 0)))]
        else:
            try:
                answers = [roundtrip(RefClass, ref_ns, args)]
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
        except Unsupported:
            raise
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
        judge(entry, actual, answers)
        report["cases"].append(entry)


def main():
    workdir = sys.argv[1]
    mode = sys.argv[2] if len(sys.argv) > 2 else "function"
    oracle = sys.argv[3] if len(sys.argv) > 3 else "reference"
    shard = int(sys.argv[4]) if len(sys.argv) > 4 else 0
    stride = int(sys.argv[5]) if len(sys.argv) > 5 else 1
    report = {"ok": True, "cases": []}

    if mode in ("class", "roundtrip"):
        runner = run_class_cases if mode == "class" else run_roundtrip_cases
        try:
            runner(workdir, report, oracle, shard, stride)
        except Unsupported as exc:
            report.update(ok=False, unsupported=True, error=str(exc))
        except Exception:
            report.update(ok=False, error=traceback.format_exc(limit=3))
        print(json.dumps(report))
        return

    with open(os.path.join(workdir, "cases.json")) as fh:
        cases = json.load(fh)

    try:
        user_prelude = solution_prelude(workdir, "user.py")
        ref_prelude = solution_prelude(workdir, "ref.py")
        UserSolution, user_ns = load_solution(
            os.path.join(workdir, "user.py"), "<your solution>", user_prelude)
        RefSolution, ref_ns = load_solution(
            os.path.join(workdir, "ref.py"), "<reference>", ref_prelude)
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
    declared = load_types(workdir)
    published = load_expected(workdir, len(cases)) if oracle == "expected" else None

    for i, block in enumerate(cases):
        if i % stride != shard:
            continue
        args = parse_input(block)
        entry = {"index": i, "input": block}

        if published is not None:
            answers = published[i]
        else:
            try:
                expected, _ = invoke(RefSolution, method, args, params, ret_ann, ref_ns, declared)
                answers = [expected]
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
            actual, logs = invoke(UserSolution, method, args, params, ret_ann, user_ns, declared)
        except Unsupported as exc:
            report["ok"] = False
            report["unsupported"] = True
            report["error"] = str(exc)
            print(json.dumps(report))
            return
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
        judge(entry, actual, answers)
        report["cases"].append(entry)

    print(json.dumps(report))


if __name__ == "__main__":
    main()
