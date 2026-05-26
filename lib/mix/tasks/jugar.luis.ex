defmodule Mix.Tasks.Jugar.Luis do
  @moduledoc """
  Abre IEx en el nodo `luis@localhost` (Terminal 2: unirse a la sala en ana).

  Antes de abrir, deja corriendo Terminal 1 con `mix jugar.ana`.
  """
  use Mix.Task

  @shortdoc "IEx como nodo luis@localhost (unirse a sala, Terminal 2)"

  @impl Mix.Task
  def run(_args) do
    Mix.Tasks.Jugar.Node.run(Mix.Tasks.Jugar.Node.sname_entrenador("luis"), [
      "Nodo luis@localhost — Terminal 2.",
      "Con Terminal 1 (ana) abierta: PokemonBattle.MenuJuego.iniciar()",
      "Al iniciar sesión como luis se conecta solo al nodo de ana.",
      "Menú 5 → 3 → mismo código S-xxxx que creó ana."
    ])
  end
end
