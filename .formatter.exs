[
  import_deps: [:phoenix, :dune],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,dev,test}/**/*.{heex,ex,exs}"]
]
