-- -*- lua -*-

help([[
OpenCode CLI - AI coding assistant
Version 2.4.1
Configured to use CHPC Qwen3 Coder as default model but use /connect and /models to use alternatives.
]])


local host = subprocess("hostname -s"):gsub("\n$", "")

if mode() == "load" and host:lower():find("redwood", 1, true) then
  LmodError("OpenCode is not available in the Protected Environment currently.\n" ..
            "CHPC staff are still testing OpenCode and the CHPC hosted coding model for data leakage.")
end

-- print out a message to the terminal
if mode() == "load" then
  LmodMessage("====================================================================")
  LmodMessage("OpenCode CLI - AI coding assistant")
  LmodMessage("Version 2.4.1")
  LmodMessage("Configured to use CHPC Qwen3 Coder as default model.")
  LmodMessage("Use /connect and /models to select alternatives like Claude or Codex")
  LmodMessage("This module CANNOT be used in the Protected Environment due to data security risks.")
  LmodMessage("====================================================================")
end


local root = "/uufs/chpc.utah.edu/sys/installdir/r8/opencode/2.4.1"
local opencode_bin = pathJoin(root, "bin", "opencode")
local agents_dir = "/uufs/chpc.utah.edu/sys/etc/agents"

-- specify install dir binaries
prepend_path("PATH", pathJoin(root, "bin"))

-- Shared site configuration and TUI settings remain in the system tree.
-- OpenCode 2 writes service state under CONFIG_DIR, which must be user-writable.
setenv("OPENCODE_CONFIG", pathJoin(agents_dir, "opencode2.json"))
setenv("OPENCODE_TUI_CONFIG", pathJoin(agents_dir, "tui.json"))
setenv("OPENCODE_CONFIG_DIR", pathJoin(os.getenv("HOME"), ".config", "opencode"))

-- -- Disable OpenTUI's OSC 66 explicit-width probes so older terminals fall back to normal width handling instead of printing artifacts.
setenv("OPENTUI_FORCE_EXPLICIT_WIDTH", "false")
set_alias("opencode", "/uufs/chpc.utah.edu/sys/installdir/r8/opencode/opencode_sndbx.sh")

whatis("Name         : OpenCode")
whatis("Version      : 2.4.1")
whatis("Category     : Development")
whatis("Installed    : 2026-11-23, by BRC")
whatis("Description  : AI coding assistant CLI configured for CHPC-hosted opensource models by default")
whatis("URL          : https://opencode.ai")
whatis("Keywords     : ai, llm, coding assistant, development, qwen, ollama")
