-- -*- lua -*-

help([[
OpenCode CLI - AI coding assistant
Version 1.18.16
Configured to use CHPC Qwen3 Coder as default model but use /connect and /models to use alternatives.
]])


local host = subprocess("hostname -s"):gsub("\n$", "")

if mode() == "load" and host:lower():find("redwood", 1, true) then
  LmodError("OpenCode is not available in the Protected Environment currently.\n" ..
            "CHPC staff are still testing OpenCode and the CHPC hosted coding model for data leakage.")
end

-- print out a message to the terminal
if mode() == "load" then
  local yel = "\27[1;33m"  -- bold yellow
  local cya = "\27[1;36m"  -- bold cyan
  local rst = "\27[0m"

  LmodMessage(cya .. "====================================================================" .. rst)
  LmodMessage(yel .. "OpenCode CLI - AI coding assistant" .. rst)
  LmodMessage(yel .. "Version 1.18.16" .. rst)
  LmodMessage(yel .. "Configured to use CHPC Qwen3 Coder as default model." .. rst)
  LmodMessage(yel .. "Use /connect and /models to select alternatives like Claude or Codex" .. rst)
  LmodMessage(yel .. "This module CANNOT be used in the Protected Environment due to data security risks." .. rst)
  LmodMessage(cya .. "====================================================================" .. rst)
end


local root = "/uufs/chpc.utah.edu/sys/installdir/r8/opencode/1.18.16"
local opencode_bin = pathJoin(root, "bin", "opencode")
local agents_dir = "/uufs/chpc.utah.edu/sys/etc/agents"

-- specify install dir binaries
prepend_path("PATH", pathJoin(root, "bin"))

-- specify path to opencode.json config, the config itself specifies the location for the skills
setenv("OPENCODE_CONFIG", pathJoin(agents_dir, "opencode.json"))
setenv("OPENCODE_CONFIG_DIR", agents_dir)

-- -- Disable OpenTUI's OSC 66 explicit-width probes so older terminals fall back to normal width handling instead of printing artifacts.
setenv("OPENTUI_FORCE_EXPLICIT_WIDTH", "false")
set_alias("opencode", "/uufs/chpc.utah.edu/sys/installdir/r8/opencode/opencode_sndbx.sh")

whatis("Name         : OpenCode")
whatis("Version      : 1.18.16")
whatis("Category     : Development")
whatis("Installed    : 2026-08-12, by BRC")
whatis("Description  : AI coding assistant CLI configured for CHPC-hosted opensource models by default")
whatis("URL          : https://opencode.ai")
whatis("Keywords     : ai, llm, coding assistant, development, qwen, ollama")
