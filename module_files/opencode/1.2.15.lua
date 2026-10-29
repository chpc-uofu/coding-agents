-- -*- lua -*-

help([[
OpenCode CLI - AI coding assistant
Version 1.2.15
Configured to use CHPC Qwen3 Coder as default model but use /connect and /models to use alternatives.
]])


local host = subprocess("hostname -s"):gsub("\n$", "")

if mode() == "load" and host:lower():find("redwood", 1, true) then
  LmodError("OpenCode is not available on to use in the Protected Environment currently.")
  LmodError("CHPC staff are still testing OpenCode and the CHPC hosted coding model for data leakage.")
end

-- print out a message to the terminal
if mode() == "load" then
  local yel = "\27[1;33m"  -- bold yellow
  local cya = "\27[1;36m"  -- bold cyan
  local rst = "\27[0m"

  LmodMessage(cya .. "====================================================================" .. rst)
  LmodMessage(yel .. "OpenCode CLI - AI coding assistant" .. rst)
  LmodMessage(yel .. "Version 1.2.15" .. rst)
  LmodMessage(yel .. "Configured to use CHPC Qwen3 Coder as default model." .. rst)
  LmodMessage(yel .. "Use /connect and /models to select alternatives." .. rst)
  LmodMessage(yel .. "This module CANNOT be used in the Protected Environment due to data security risks." .. rst)
  LmodMessage(cya .. "====================================================================" .. rst)
end


local root = "/uufs/chpc.utah.edu/sys/installdir/r8/opencode/1.2.15"

prepend_path("PATH", pathJoin(root, "bin"))
setenv("OPENCODE_CONFIG_DIR", pathJoin(root, "/etc"))
setenv("OPENCODE_TUI_CONFIG", pathJoin(root, "/etc/tui.json"))
setenv("OPENTUI_FORCE_EXPLICIT_WIDTH", "false")

-- -- Disable OpenTUI's OSC 66 explicit-width probes so older terminals fall back to normal width handling instead of printing artifacts.
setenv("OPENTUI_FORCE_EXPLICIT_WIDTH", "false")


whatis("Name         : OpenCode")
whatis("Version      : 1.2.15")
whatis("Category     : Development")
whatis("Installed    : 2026-02-27, by BRC")
whatis("Description  : AI coding assistant CLI configured for CHPC-hosted Qwen-Coder-Next by default")
whatis("URL          : https://opencode.ai")
whatis("Keywords     : ai, llm, coding assistant, development, qwen, ollama")
