local M = {}

---@class meatcode.Config
local defaults = {
	-- Which list to show on the roadmap: "neetcode150" | "blind75" | "neetcode250" | "allNC"
	list = "neetcode150",

	-- Language used for starter code, local runs and submissions.
	lang = "python",

	-- Where solutions are written. Files live at <dir>/<pattern-slug>/<problem-id>.<ext>
	solutions_dir = vim.fn.stdpath("data") .. "/meatcode/solutions",

	-- Cache for the scraped catalog and problem metadata.
	cache_dir = vim.fn.stdpath("cache") .. "/meatcode",

	-- Refresh cached catalogs in the background when they become this old.
	-- Set to false to keep cached catalogs until they are missing.
	catalog_max_age = 24 * 60 * 60,

	-- Seconds before a network call is abandoned.
	timeout = 30,

	runner = {
		-- Remote reference/editorial/community code is untrusted. Oracle
		-- validation and output caching run without network, home or host
		-- filesystem access: bubblewrap (`bwrap`) on Linux, Apple's
		-- `sandbox-exec` on macOS. Your solution runs separately, unsandboxed.
		-- Set false only to accept native provider-code execution as your user.
		sandbox = true,
		-- Test cases run in separate processes. 0 uses the smaller of case count
		-- and available CPU count; 1 forces sequential execution.
		parallelism = 0,
		python = {
			cmd = { "python3" },
			-- Prepend a `from typing import *` and any helper types (ListNode,
			-- TreeNode, a problem-specific Node/Interval, ...) a starter
			-- references but never defines, because the judge supplies them
			-- implicitly. Stripped back out before every local run and
			-- submission -- see lua/meatcode/runner/python_prelude.lua.
			auto_imports = true,
		},
		cpp = {
			-- {source} and {out} are substituted at build time. Keep debug symbols
			-- and disable optimisation so an LLDB rerun can show source backtraces.
			cmd = { "c++", "-std=c++23", "-g", "-O0", "-o", "{out}", "{source}" },
			-- Drop a `.clangd` beside your solutions that force-includes a header
			-- supplying the #includes and node types NeetCode's judge provides
			-- implicitly, so a language server stops flagging valid solutions.
			-- Compile flags (including `-std`) are taken from `cmd` above.
			-- Nothing is added to your file and nothing extra is submitted.
			clangd = true,
		},
		-- Per-test-case wall clock limit, in seconds.
		time_limit = 10,
	},

	ui = {
		-- Roadmap node width in cells. Node labels are centred inside this.
		node_width = 24,
		border = "rounded",
		-- The roadmap is navigated with a highlighted node, so the terminal cursor
		-- is just noise; hide it while that window has focus.
		hide_cursor = true,
		-- Draw problem diagrams inline with image.nvim, where the terminal can.
		images = true,
		image_max_height = 18,
	},

	keys = {
		roadmap = {
			open = "<CR>",
			quit = "q",
			cycle_list = "L",
		},
		home = {
			roadmap = "r",
			list = "l",
			random = "n",
			daily = "d",
		},
		problem = {
			run = "<leader>nr",
			submit = "<leader>ns",
			tests = "<leader>nt",
			test_failed = "<leader>na",
			reset = "<leader>nR",
			-- Fuzzy-pick one of the statement's links (provider pages,
			-- solutions, video) and open it in the browser.
			links = "<leader>no",
			-- Edit the content/submit provider fallback chains.
			configure = "<leader>nc",
			quit = "q",
		},
	},
}

---@type meatcode.Config
M.options = vim.deepcopy(defaults)
M.defaults = defaults

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
	return M.options
end
return M
