-- -*- lua -*-

local version = "2.1.83"

help([[
        Claude Code CLI: AI-powered coding assistant
]])

local host = subprocess("hostname -s"):gsub("\n$", "")
if mode() == "load" and host:lower():find("redwood", 1, true) then
  LmodError("Claude Code is not available in the Protected Environment.")
end


whatis("Name         : Claude Code")
whatis("Version      : " .. version)
whatis("Category     : AI, Programming")
whatis("Description  : AI-powered coding assistance")
whatis("URL          : https://code.claude.com/docs/en/overview")
whatis("Installed on : 03/25/2026")
whatis("Modified on  : 2026-04-15, BRC")
whatis("Installed by : WRC")


local base = pathJoin("/uufs/chpc.utah.edu/sys/installdir/r8", myModuleName(), version)
prepend_path("PATH",pathJoin(base,"bin"))

