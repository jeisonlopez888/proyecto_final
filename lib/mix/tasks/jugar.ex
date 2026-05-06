defmodule Mix.Tasks.Jugar do
  @moduledoc false
  use Mix.Task

  @shortdoc "Abre el menú interactivo del juego (consola con números)"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    PokemonBattle.MenuJuego.iniciar()
  end
end
