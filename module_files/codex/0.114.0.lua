-- -*- lua -*-

help([[
Codex CLI - AI coding assistant
Version 0.114.0
OpenAI's command-line interface for code generation and programming assistance.
]])

local host = subprocess("hostname -s"):gsub("\n$", "")

if mode() == "load" and host:lower():find("redwood", 1, true) then
  LmodError("Codex is not available on to use in the Protected Environment due to potential data leakage.")
end


-- print out a message to the terminal about Codex sign-in process
if mode() == "load" then
  local function line(char)
  local cols = tonumber(os.getenv("COLUMNS")) or 90
    return string.rep(char or "=", cols)
end

  LmodMessage(line("="))
  LmodMessage("Note on Codex sign-in: Device code sign-in is supported only for personal accounts.")
  LmodMessage("University of Utah accounts must authenticate with the browser link")
  LmodMessage("using ssh -X, FastX, or an Open OnDemand desktop session.")
  LmodMessage("Running out of tokens? Try module load codex_CHPC_local_model")
  LmodMessage("to run the local CHPC model in the Codex TUI.")
  LmodMessage(line("="))
end


load("nodejs/22.4.0")

local version = "0.114.0"
local root = pathJoin("/uufs/chpc.utah.edu/sys/installdir/r8/codex", version)

prepend_path("PATH", pathJoin(root, "bin"))

whatis("Name         : Codex")
whatis("Version      : 0.114.0")
whatis("Category     : Development")
whatis("Installed    : 2026-04-16, BRC")
whatis("Description  : AI coding assistant TUI by OpenAI")
whatis("URL          : https://github.com/openai/codex")
whatis("Keywords     : ai, llm, coding assistant, development, openai")


