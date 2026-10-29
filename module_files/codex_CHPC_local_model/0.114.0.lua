-- -*- lua -*-

help([[
Codex CLI - AI coding assistant (CHPC open-models build)
Version 0.114.0

Runs the OpenAI Codex TUI against the CHPC-hosted Qwen3 Coder model on nimbus
instead of api.openai.com. No prompt, file, or command content leaves CHPC
hardware, and no OpenAI sign-in is required.

Use /model inside the TUI to see and select the CHPC-hosted models. Only the
models listed in /uufs/chpc.utah.edu/sys/etc/agents/codex_model_catalog.json are
offered; OpenAI's hosted models are not reachable from this module. Load
codex/0.114.0 instead if you want the OpenAI-hosted models.
]])

local host = subprocess("hostname -s"):gsub("\n$", "")

if mode() == "load" and host:lower():find("redwood", 1, true) then
  LmodError("Codex is not available to use in the Protected Environment due to potential data leakage.")
end

if mode() == "load" then

  LmodMessage("====================================================================")
  LmodMessage("Codex CLI 0.114.0 - running CHPC open model")
  LmodMessage("Currently serving  Qwen 3.8 Coder 27B")
  LmodMessage("No OpenAI sign-in is required and prompts stay on CHPC hardware.")
  LmodMessage("This module CANNOT be used in the Protected Environment.")
  LmodMessage("====================================================================")
end

load("nodejs/22.4.0")

local root = pathJoin("/uufs/chpc.utah.edu/sys/installdir/r8/codex_CHPC_local_model/0.114.0")

prepend_path("PATH", pathJoin(root, "bin"))

-- The local inference server does not authenticate, but Codex requires the
-- provider's env_key to be set to something non-empty before it will start.
setenv("CHPC_CODER_API_KEY", "CHPC_OPEN_MODEL")

whatis("Name         : Codex (CHPC open models)")
whatis("Version      : 0.114.0_local_model")
whatis("Category     : Development")
whatis("Installed    : 2026-08-28, BRC")
whatis("Description  : AI coding assistant TUI by OpenAI, wired to CHPC-hosted open-weights models")
whatis("URL          : https://github.com/openai/codex")
whatis("Keywords     : ai, llm, coding assistant, development, qwen, vllm")
