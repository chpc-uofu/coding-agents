-- -*- lua -*-

local version = "1.1.1"


help([[
Antigravity CLI - Google's AI assistant for the terminal
Version ]] .. version .. [[

Google's command-line interface for interacting with Gemini AI models,
supporting multi-turn conversations, file context, and tool use. Antigravity is the successor to
Gemini CLI. Gemini CLI was written in Typescript while Antigravity is written in Go. Use
"antigravity" to invoke the program. Note that this is different from the "agy" command for the
1.0.6 version.
]])

local host = (os.getenv("HOSTNAME") or ""):lower()
if mode() == "load" and host:find("redwood", 1, true) then
  LmodError("Gemini CLI is not available in the Protected Environment due to potential data leakage.")
end

local base = pathJoin("/uufs/chpc.utah.edu/sys/installdir/r8", myModuleName(), version)

prepend_path("PATH", pathJoin(base, "bin"))


set_shell_function("agy",                                                                                                                                           
   pathJoin(base, "bin/agy") .. ' --add-dir /uufs/chpc.utah.edu/sys/etc/agents "$@"',
   pathJoin(base, "bin/agy") .. ' --add-dir /uufs/chpc.utah.edu/sys/etc/agents $*')

whatis("Name         : antigravity")
whatis("Version      : " .. version)
whatis("Category     : AI Tools")
whatis("Installed    : 2026-07-13, BRC")
whatis("Description  : Google Antigravity CLI - AI assistant in the terminal")
whatis("URL          : https://github.com/google-gemini/gemini-cli")
whatis("Keywords     : ai, llm, gemini, antigravity, google, assistant")
