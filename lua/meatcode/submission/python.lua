--- Python cross-provider submission entry-point adapter.
--- Uses real Python AST via python3 to distinguish actual class Solution methods
--- from decoys, checks compatible positional arity (excluding self), and safely
--- injects a forwarding method into class Solution.
local M = {}

local SCRIPT = [=[
import ast
import json
import sys

def get_pos_args(fn):
    positional = list(fn.args.posonlyargs) + list(fn.args.args)
    if (isinstance(fn, ast.AsyncFunctionDef) or fn.decorator_list
            or fn.args.kwonlyargs or fn.args.vararg or fn.args.kwarg
            or fn.args.defaults or not positional):
        raise ValueError("only ordinary positional instance methods can be adapted")
    return [arg.arg for arg in positional[1:]]

def run():
    try:
        raw = sys.stdin.read()
        data = json.loads(raw)
    except Exception as e:
        return {"ok": False, "error": f"invalid input: {e}"}

    code = data.get("code", "")
    starter = data.get("starter", "")
    judge_starter = data.get("judge_starter", "")

    # 1. Parse judge starter
    try:
        j_tree = ast.parse(judge_starter)
    except Exception as e:
        return {"ok": False, "error": f"could not read the judge's Python signature: {e}"}

    j_sol = next((n for n in j_tree.body if isinstance(n, ast.ClassDef) and n.name == "Solution"), None)
    if not j_sol:
        return {"ok": False, "error": "could not read the judge's Python signature: could not find class Solution"}

    j_methods = [n for n in j_sol.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]
    if not j_methods:
        return {"ok": False, "error": "could not read the judge's Python signature: no method found"}
    target_fn = j_methods[0]
    target_name = target_fn.name

    # 2. Parse user solution code
    try:
        c_tree = ast.parse(code)
    except Exception as e:
        return {"ok": False, "error": f"could not parse Python solution: {e}"}

    c_sol = next((n for n in c_tree.body if isinstance(n, ast.ClassDef) and n.name == "Solution"), None)
    if not c_sol:
        return {"ok": False, "error": "could not find class Solution in Python solution"}

    c_methods = {
        n.name: n for n in c_sol.body
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
    }

    # An existing actual judge method takes precedence
    if target_name in c_methods:
        return {"ok": True, "payload": code}

    # 3. Parse content provider starter
    try:
        s_tree = ast.parse(starter)
    except Exception as e:
        return {"ok": False, "error": f"could not read the content provider's Python signature: {e}"}

    s_sol = next((n for n in s_tree.body if isinstance(n, ast.ClassDef) and n.name == "Solution"), None)
    if not s_sol:
        return {"ok": False, "error": "could not read the content provider's Python signature: could not find class Solution"}

    s_methods = [n for n in s_sol.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]
    if not s_methods:
        return {"ok": False, "error": "could not read the content provider's Python signature: no method found"}
    source_fn = s_methods[0]
    source_name = source_fn.name

    if source_name == target_name:
        return {"ok": True, "payload": code}

    if source_name not in c_methods:
        return {"ok": False, "error": f"Python solution must implement `{source_name}` or `{target_name}`"}

    # 4. Check positional arity compatibility, excluding self
    try:
        s_pos = get_pos_args(source_fn)
        t_pos = get_pos_args(target_fn)
        implemented_pos = get_pos_args(c_methods[source_name])
    except ValueError as e:
        return {"ok": False, "error": str(e)}
    if len(implemented_pos) != len(s_pos):
        return {"ok": False, "error": "the solution method does not match the content starter's arity"}
    if len(s_pos) != len(t_pos):
        return {"ok": False, "error": "Python entry-point signatures differ in parameter count; use the judge's starter"}

    # 5. Build forwarding method and insert into class Solution
    lines = code.splitlines(True)
    first_fn = next((n for n in c_sol.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))), None)
    if first_fn:
        start_line = min([d.lineno for d in getattr(first_fn, 'decorator_list', [])] + [first_fn.lineno])
        line_idx = start_line - 1
        line_text = lines[line_idx]
        indent = line_text[:len(line_text) - len(line_text.lstrip())]
    else:
        line_idx = c_sol.lineno
        indent = "    "
    if not indent:
        indent = "    "

    param_decls = ["self"] + list(t_pos)
    call_args = list(t_pos)

    forwarding = (
        f"{indent}def {target_name}({', '.join(param_decls)}):\n"
        f"{indent}    return self.{source_name}({', '.join(call_args)})\n"
    )
    lines.insert(line_idx, forwarding)
    return {"ok": True, "payload": "".join(lines)}

if __name__ == "__main__":
    out = run()
    sys.stdout.write(json.dumps(out))
]=]

local function python_cmd()
  return vim.deepcopy(require("meatcode.config").options.runner.python.cmd)
end

--- Bridge compatible provider entry points in the payload, never the buffer.
--- Preserves exact declared code, recursion, helper methods, comments, and string literals.
--- Uses real Python AST to parse signatures, detect Solution methods, and verify positional arity.
---@param code string
---@param starter string
---@param judge_starter string
---@return string|nil payload, string|nil err
function M.adapt_submission(code, starter, judge_starter)
  local input = vim.json.encode({
    code = code or "",
    starter = starter or "",
    judge_starter = judge_starter or "",
  })
  local cmd = python_cmd()
  table.insert(cmd, "-c")
  table.insert(cmd, SCRIPT)

  local proc = vim.system(cmd, { stdin = input, text = true }):wait()
  if proc.code ~= 0 then
    local err = proc.stderr ~= "" and proc.stderr or ("python process exited with code " .. proc.code)
    return nil, "Python adaptation error: " .. err
  end

  local ok, res = pcall(vim.json.decode, proc.stdout)
  if not ok or type(res) ~= "table" then
    return nil, "could not parse Python adaptation output: " .. tostring(proc.stdout)
  end

  if not res.ok then
    return nil, res.error or "Python adaptation failed"
  end

  return res.payload
end

return M
