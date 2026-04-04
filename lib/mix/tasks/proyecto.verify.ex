defmodule Mix.Tasks.Proyecto.Verify do
  @moduledoc false
  use Mix.Task

  @shortdoc "Verifica el proyecto: ejecuta la suite ExUnit (requisitos funcionales)"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("test", args)
  end
end
