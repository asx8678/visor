# TodoApp

A small to-do list library: the example `mix visor.example` (in Visor)
runs the agent on.

- `lib/todo_app.ex` keeps the list as plain data; `lib/todo_app/store.ex`
  keeps one in an `Agent` process.
- Check changes with `V.check()`. Fix the code in `lib/`, never the tests.
- Keep answers short.
