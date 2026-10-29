# codex_CHPC_local_model 0.153.4 staging

Install this directory as the `0.153.4` local-model payload and install the
modulefile as `codex_CHPC_local_model/0.153.4.lua` in the CHPC-r8 Core module
tree.

The directory intentionally contains the site-specific wrapper, not the 258 MB
Codex executable. Place the existing verified standard Codex binary at:

```text
/uufs/chpc.utah.edu/sys/installdir/r8/codex_CHPC_local_model/0.153.4/bin/codex-real
```

The source binary is the deployed 0.153.4 payload at:

```text
/uufs/chpc.utah.edu/sys/installdir/r8/codex/0.153.4/bin/codex-real
```

No `bwrap` copy is needed: the wrapper uses `/usr/bin/bwrap` only when
`CHPC_CODEX_MASK_NETWORK=1`. Install `etc/codex_model_catalog.json` as:

```text
/uufs/chpc.utah.edu/sys/etc/agents/codex_CHPC_local_model/0.153.4/codex_model_catalog.json
```

This versioned catalog changes `apply_patch_tool_type` from `function` to
`freeform`, which Codex 0.153.4 requires. The shared CHPC linker remains at its
existing `/uufs/chpc.utah.edu/sys/etc/agents/...` path.

Smoke test after installation:

```bash
module load codex_CHPC_local_model/0.153.4
codex --strict-config --version
codex debug models >/dev/null
```

These commands parse the wrapper's configuration and catalog without starting a
chat or contacting the inference service.
