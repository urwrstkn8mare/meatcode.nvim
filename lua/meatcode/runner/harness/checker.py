"""Grades outputs with an openleetcode checker (meatcode.nvim).

openleetcode manifests carry an `oracle.python3` section: a `Checker` class and
a call expression such as `Checker().longestPalindrome(s, {result})`. The
arguments are plain names bound to the case's JSON values (trees and linked
lists stay level-order / plain lists), and `{result}` is the solution's output
decoded from JSON. The call must return exactly `True` to accept.

Usage: python3 checker.py <workdir> [shard] [stride]
Reads checker.json ({source, call, params, utilities}), cases.json (case
blocks, arguments in signature order) and outputs.json (each case's output as
JSON text, or null when there is none) from <workdir>. `harness.py` (the
local-run harness) must sit beside it; its input parser is reused. Prints a
JSON report whose cases are `pass`, `fail`, `oracle_error` or `no_oracle`.
"""
import __future__
import json
import os
import sys
import traceback

from harness import parse_input

# The namespace openleetcode's own oracle program gives a checker.
PRELUDE = """
import sys
import time as _time
import math
import heapq
import bisect
import itertools
import collections
import json
import datetime as _dt
from dataclasses import is_dataclass, asdict
from typing import *
from functools import *
from collections import *
from heapq import *
from bisect import *
"""

# Annotations stay unevaluated, so a checker written for a newer Python than the
# one available still loads.
FLAGS = __future__.annotations.compiler_flag


def load(spec):
    namespace = {}
    exec(PRELUDE, namespace)
    for name, source in (("<openleetcode utilities>", spec.get("utilities")),
                         ("<openleetcode checker>", spec["source"])):
        if source:
            exec(compile(source, name, "exec", flags=FLAGS, dont_inherit=True), namespace)
    call = compile(spec["call"].replace("{result}", "__result__"), "<checker call>", "eval")
    return namespace, call


def main():
    workdir = sys.argv[1]
    shard = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    stride = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    report = {"ok": True, "cases": []}

    with open(os.path.join(workdir, "checker.json")) as fh:
        spec = json.load(fh)
    with open(os.path.join(workdir, "cases.json")) as fh:
        cases = json.load(fh)
    with open(os.path.join(workdir, "outputs.json")) as fh:
        outputs = json.load(fh)

    try:
        namespace, call = load(spec)
    except Exception:
        report.update(ok=False, error="the checker does not load:\n" + traceback.format_exc(limit=3))
        print(json.dumps(report))
        return

    params = spec["params"]
    for i, block in enumerate(cases):
        if i % stride != shard:
            continue
        entry = {"index": i, "input": block}
        output = outputs[i] if i < len(outputs) else None
        if output is None:
            entry["status"] = "no_oracle"
            report["cases"].append(entry)
            continue
        entry["actual"] = output
        try:
            values = [value for _, value in parse_input(block)]
            if len(values) != len(params):
                raise ValueError("the case has %d argument(s); the checker takes %d (%s)"
                                 % (len(values), len(params), ", ".join(params)))
            scope = dict(namespace)
            scope.update(zip(params, values))
            scope["__result__"] = json.loads(output)
            entry["status"] = "pass" if eval(call, scope) is True else "fail"
        except Exception:
            entry["status"] = "oracle_error"
            entry["error"] = traceback.format_exc(limit=3)
        report["cases"].append(entry)

    print(json.dumps(report))


if __name__ == "__main__":
    main()
