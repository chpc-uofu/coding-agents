-- -*- lua -*-

local version = "2.1.284"

help([[
        Claude Code CLI: AI-powered coding assistant
]])

local host = subprocess("hostname -s"):gsub("\n$", "")
if mode() == "load" and host:lower():find("redwood", 1, true) then
  LmodError("Claude Code is not available in the Protected Environment.")
end

-- print out a message to the terminal raising awareness of open model alternative to Claude.
if mode() == "load" then
    local bar = string.rep("=", 90)
   LmodMessage(bar)
   LmodMessage("Running out of tokens? Try module load codex_CHPC_local_model")
   LmodMessage("to run the local CHPC model in the Codex TUI.")
   LmodMessage(bar)
   end


whatis("Name         : Claude Code")
whatis("Version      : " .. version)
whatis("Category     : AI, Programming")
whatis("Description  : AI-powered coding assistance")
whatis("URL          : https://code.claude.com/docs/en/overview")
whatis("Installed on : 2026-09-28, by BRC")


local base = pathJoin("/uufs/chpc.utah.edu/sys/installdir/r8", myModuleName(), version)
prepend_path("PATH",pathJoin(base,"bin"))

