local M = {}

---@class neetcode.Config
local defaults = {
	-- Which list to show on the roadmap: "neetcode150" | "blind75" | "neetcode250" | "allNC"
	list = "neetcode150",

	-- Language used for starter code, local runs and submissions.
	lang = "python",

	-- Where solutions are written. Files live at <dir>/<pattern-slug>/<problem-id>.<ext>
	solutions_dir = vim.fn.stdpath("data") .. "/neetcode/solutions",

	-- Cache for the scraped catalog and problem metadata.
	cache_dir = vim.fn.stdpath("cache") .. "/neetcode",

	-- Refresh the scraped catalog if the cached copy is older than this (seconds).
	-- Set to false to only ever refresh via :NeetCode sync.
	catalog_max_age = 24 * 60 * 60,

	-- Seconds before a network call is abandoned.
	timeout = 30,

	runner = {
		python = { cmd = { "python3" } },
		cpp = {
			-- {source} and {out} are substituted at build time.
			cmd = { "c++", "-std=c++23", "-O2", "-o", "{out}", "{source}" },
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
			sync = "R",
		},
		problem = {
			run = "<leader>nr",
			submit = "<leader>ns",
			tests = "<leader>nt",
			test_failed = "<leader>na",
			quit = "q",
		},
	},
}

---@type neetcode.Config
M.options = vim.deepcopy(defaults)
M.defaults = defaults

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
	return M.options
end

return M
