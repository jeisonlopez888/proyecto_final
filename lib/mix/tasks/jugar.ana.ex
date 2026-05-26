defmodule Mix.Tasks.Jugar.Ana do
  @moduledoc """
  Abre IEx en el nodo `ana@localhost` (Terminal 1: crea la sala de batalla).

  En Windows usa `iex.bat` con cookie `proyecto_pokemon` (o `ERL_COOKIE` si ya la definiste).
  """
  use Mix.Task

  @shortdoc "IEx como nodo ana@localhost (crear sala, Terminal 1)"

  @impl Mix.Task
  def run(_args) do
    Mix.Tasks.Jugar.Node.run(Mix.Tasks.Jugar.Node.sname_entrenador("ana"), [
      "Nodo ana@localhost — Terminal 1 (crea la sala).",
      "PokemonBattle.MenuJuego.iniciar() → login ana.",
      "O usa iex.bat -S mix: el nodo se configura al iniciar sesión.",
      "",
      "Terminal 2: otro usuario (luis) en otra ventana."
    ])
  end
end
