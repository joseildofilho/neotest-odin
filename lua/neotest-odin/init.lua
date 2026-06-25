local lib = require("neotest.lib")
local async = require("neotest.async")
local nio = require("nio")

---@type neotest.Adapter
local adapter = { name = "neotest-odin", dap = { adapter = "" } }

adapter.root = lib.files.match_root_pattern(".git")

local has_parser, _ = vim.treesitter.language.add("odin")
if not has_parser then
	print("missing odin parser, run TSInstall odin")
	return
else
	print("odin parser is present")
end

function adapter.is_test_file(file_path)
	return vim.endswith(file_path, "_test.odin")
end

function adapter.discover_positions(file_path)
	local query = [[
    (package_declaration (identifier) @namespace.name) @namespace.definition

    (procedure_declaration
      (attributes
        (attribute
          (identifier) @_attr (#eq? @_attr "test")))
      (identifier) @test.name
    ) @test.definition
  ]]

	local namespace = ""
	local tree = lib.treesitter.parse_positions(file_path, query, {
		require_namespaces = false,
		nested_tests = false,
		position_id = function(position, _)
			if position.type == "namespace" then
				assert(namespace == "", "double namespace?")
				namespace = position.name
			end

			if position.type == "test" then
				local id = namespace .. "." .. position.name
				return id
			end

			return ""
		end,
	})
	return tree
end

---@async
---@param args neotest.RunArgs
---@return neotest.RunSpec
function adapter.build_spec(args)
	local results_path = async.fn.tempname()
	local position = args.tree:data()
	local location = position.path

	if vim.fn.isdirectory(position.path) ~= 1 then
		location = vim.fn.fnamemodify(position.path, ":h")
	end

	local ids = {}
	for _, node in args.tree:iter_nodes() do
		local value = node:data()
		if value.type == "test" then
			table.insert(ids, value.id)
		end
	end
	local test_names = vim.fn.join(ids, ",")

	local bin_path = async.fn.tempname()

	if args.strategy == "dap" then
		-- build a temp binary.
		local future = nio.control.future()
		local build_command = {
			"odin",
			"build",
			location,
			"-debug",
			"-build-mode:test",
			"-all-packages",
			"-error-pos-style:unix",
			"-out:" .. bin_path,
			"-define:ODIN_TEST_FANCY=false",
			"-define:ODIN_TEST_NAMES=" .. test_names,
			"-define:ODIN_TEST_JSON_REPORT=" .. results_path,
			"-define:ODIN_TEST_GO_TO_ERROR=true",
		}
		vim.system(build_command, { text = true }, function(out)
			if out.code == 0 then
				future.set()
			else
				future.set_error(out.stderr)
			end
		end)
		local build_success, build_error_message = pcall(future.wait)

		return {
			cwd = location,
			context = {
				strategy = "dap",
				results_path = results_path,
				build_success = build_success,
				build_error_message = build_error_message,
			},
			-- TODO: should be configurable.
			strategy = {
				name = "Debug Test",
				type = "codelldb",
				request = "launch",
				initCommands = {
					"command source ~/.lldbinit",
				},
				program = bin_path,
			},
		}
	else
		local result = {
			command = 'odin test . -all-packages -error-pos-style:unix -out:"'
				.. bin_path
				.. '" -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_NAMES='
				.. test_names
				.. ' -define:ODIN_TEST_JSON_REPORT="'
				.. results_path
				.. '" -define:ODIN_TEST_GO_TO_ERROR=true',
			cwd = location,
			context = {
				results_path = results_path,
			},
		}
		return result
	end
end

function adapter.results(spec, _, tree)
	local results = {}

	-- Build failure with DAP strategy.
	if spec.context.strategy == "dap" and not spec.context.build_success then
		local out_path = async.fn.tempname()
		lib.files.write(out_path, spec.context.build_error_message)

		for _, node in tree:iter_nodes() do
			local value = node:data()
			results[value.id] = {
				status = "skipped",
				short = spec.context.build_error_message,
				output = out_path,
			}
		end

		results[tree:data().id] = {
			status = "failed",
			short = spec.context.build_error_message,
			output = out_path,
		}

		return results
	end

	local ok, output = pcall(lib.files.read, spec.context.results_path)
	-- If there is no test report compiling must've failed, set first node as failed, rest as skipped.
	if not ok then
		for _, node in tree:iter_nodes() do
			local value = node:data()
			results[value.id] = {
				status = "skipped",
			}
		end

		results[tree:data().id] = {
			status = "failed",
		}

		return results
	end

	local report = vim.json.decode(output)
	for _, node in tree:iter_nodes() do
		local value = node:data()

		if value.type == "test" then
			-- Mark as skipped when it doesn't come up in the report.
			results[value.id] = {
				status = "skipped",
			}

			local parts = vim.split(value.id, ".", { plain = true })
			local pkg = parts[1]
			local name = parts[2]

			local pkg_tests = report.packages[pkg]
			if pkg_tests then
				for _, test in ipairs(pkg_tests) do
					if test.name == name then
						if test.success then
							results[value.id] = {
								status = "passed",
							}
						else
							results[value.id] = {
								status = "failed",
								-- short  = map_short(test.errors, spec.cwd),
								-- errors = map_errors(test.errors, value.path),
							}
						end
						break
					end
				end
			end
		end
	end

	return results
end

return adapter
