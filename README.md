# Visor

An agent harness: a Phoenix LiveView console for a coding agent that runs
under OTP supervision, with the live supervision tree beside it.

The agent talks to DeepSeek and has one tool, `elixir`: each step is a short
script, run in a Dune sandbox, that works on the project through `V`
(`V.read`, `V.edit`, `V.grep`, `V.sh`, `V.check` and the rest, in `lib/v.ex`).
Every path goes through `Visor.Workspace`, which keeps it inside the project
and refuses `.env` files.

## Running it

1. Put the key in a `.env` file in the project folder (it is gitignored):

       DEEPSEEK_API_KEY=...

   `DEEPSEEK_BASE_URL` and `DEEPSEEK_MODEL` there override the defaults in
   `config/config.exs`.

2. `mix setup`, then `mix phx.server` (or `iex -S mix phx.server`).
3. Open [localhost:4000](http://localhost:4000).

## When something goes wrong

Each console session writes a log under `log/sessions/`.

    mix visor.log                 # the sessions, newest last
    mix visor.log latest          # one session's timeline
    mix visor.log ID --request N  # model call N's request, as sent
    mix visor.log server          # the server log since the last start

## Working on it

`AGENTS.md` explains how the parts fit together and the rules to keep.
Run `mix precommit` before committing.
