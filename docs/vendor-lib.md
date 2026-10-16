# Vendored `lib/` — origin and rules

`lib/stt.js`, `lib/llm-client.js` and `lib/local-llm-manager.js` are vendored
from the sibling plugin
[opencode-voice](https://github.com/gabriel-macherini/opencode-voice)
(first vendored in commit `aa35d3e` "standalone install"; `session.js` and
the sox/`rec.ps1` recording path came along but are unreachable here —
`sox` recording, `registerSTT`, `appendTranscription`, `doTranscribePipeline`
and macOS `system_profiler` device listing are dead in this app).

Rules:

- Don't hand-edit pipeline semantics in `lib/`; change behavior in
  `runner.mjs` (runtime config, lifecycle) or `prompts/` (normalizer text).
- Exception: `STT_SYSTEM_PROMPT` in `lib/stt.js` is the emergency fallback
  when `promptFile` is missing. It must stay byte-identical to
  `prompts/stt-system-prompt.md` (minus the leading `<!-- -->` doc block) —
  `test/units.test.mjs` ("prompt sync") enforces this, and
  `npm run prompt:check` verifies it on demand.
- Re-vendoring: copy the three files from opencode-voice, run the tests,
  and record the upstream commit here.
