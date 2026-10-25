# TodoApp: the example Visor runs on

A small to-do list library with a bug in it on purpose, for
`mix visor.example` in Visor. Run it from Visor's root:

    mix visor.example             # the harness, then the model
    mix visor.example --offline   # the harness only: no model call
    mix visor.example --budget 0.25 --timeout 300

Each run copies this folder to `visor-example-runs/STAMP/` in the system's
temporary folder (once per phase), so the bug is here for the next run. The
newest 5 finished runs' copies are kept, and an unfinished run's for a day.
`mix precommit` runs it `--offline`.

## What it checks

**offline**, scripts through the `elixir` tool as the model's would, with no
model call: `V.ls`, `V.read`, `V.grep`, `V.glob`, `V.exists?`; that `.env`,
paths outside the project and `File` itself are refused; `V.write` and
`V.edit`; the arguments' repairs (a Python-style heredoc, code under another
key); `V.sh`; `V.check` failing on the bug, `V.attempt` putting a wrong fix
back, and `V.check` passing once it is fixed; `V.docs`, `V.source`,
`V.calls`, `V.all`; background, monitored and stopped jobs; `V.image` and
`"picture:NAME"`; `V.remember`/`V.memories`/`V.forget`; `V.save`/`V.run`; a
prompt's variables; `V.context`, `V.note`; the breaker and the alarms; the
session log; that the agent never restarted; how the DeepSeek client reads
the provider's refusals (a local stand-in answers 413, 400, 422 and 401); a
sandboxed call that exits fails its script instead of crashing.

**loop**, the agent's own loop with a scripted model in place of DeepSeek (no
network; it refuses a request whose messages are out of order): the tool loop;
a steering message after a script's result; Stop during a model call and
during a script, then a working prompt; the prompt's spending limit; a
sub-agent's spending in its parent's, with the parent suspended mid-way; wakes
when jobs end, up to the limit, then the notice with the next prompt; the
repeat guard; compaction on request with `V.recall`, and past the threshold;
a context overflow compacted and retried once; a 413 from a picture retried
without it; malformed tool arguments. Each fails if the agent's messages
needed Repair.

**live**, prompts to the model (DeepSeek, with the settings in Visor's
`.env`), each held to `--budget` dollars:

1. it finds the bug, fixes `lib/` (not the tests) and runs `V.check`, while a
   steering message comes in; `mix test` is run again afterwards
2. a background job wakes it when it ends
3. it reads a picture the user sends
4. a later prompt brings that picture back with `V.image("picture:red.png")`,
   the earlier one left out of the requests
5. a sub-agent's tokens count in its parent's prompt
6. no prompt failed, ran out of budget or crashed the agent

## What it writes

In `log/example/STAMP/` (the newest 20 runs are kept):

- `report.md`: each check, passed or failed and why, with its scripts or
  prompt, what came back, the scripts the model ran, its answer and what
  each prompt used. It is written again after each check and marked
  incomplete until the run ends, so a run you stop still leaves one.
- `events.jsonl`: every event of every session from its first (the
  sub-agents' too) and the run's own steps, one JSON object a line
- for an offline run, `sessions/` and `server/`: its session logs and server
  log (`mix visor.log ID --full --dir DIR`, `mix visor.log server --dir
  DIR`). A live run's go to `log/sessions/` and `log/server/` as always.

The task exits with 1 when a check failed.
