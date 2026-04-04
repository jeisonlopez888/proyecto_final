defmodule PokemonBattle.IntercambioTest do
  use ExUnit.Case, async: false

  alias PokemonBattle.GestorEntrenadores
  alias PokemonBattle.GestorSalas
  alias PokemonBattle.Persistencia

  defp nuevo_usuario(base), do: "#{base}_#{System.unique_integer([:positive])}"

  defp crear_y_agregar_pokemon(usuario, especie, stats, movimientos, rareza \\ "comun") do
    {:ok, id} =
      Persistencia.crear_instancia_pokemon(%{
        "especie" => especie,
        "dueño_original" => usuario,
        "rareza" => rareza,
        "ataque" => stats[:ataque],
        "defensa" => stats[:defensa],
        "velocidad" => stats[:velocidad],
        "movimientos" => movimientos
      })

    :ok = Persistencia.agregar_al_inventario(usuario, id)
    id
  end

  test "intercambio funciona (se intercambia dueño_original y se actualiza inventario)" do
    u1 = nuevo_usuario("inter_a")
    u2 = nuevo_usuario("inter_b")

    {:ok, _} = GestorEntrenadores.iniciar(u1, "1234")
    {:ok, _} = GestorEntrenadores.iniciar(u2, "1234")

    id1 = crear_y_agregar_pokemon(u1, "pikachu", %{ataque: 50, defensa: 100, velocidad: 40}, ["impactrueno", "rayo", "Destructor", "Hiperrayo"])
    id2 = crear_y_agregar_pokemon(u2, "squirtle", %{ataque: 45, defensa: 100, velocidad: 20}, ["hidrobomba", "pistola_agua", "Destructor", "Hiperrayo"])

    {:ok, room_id} = GestorSalas.crear_sala_intercambio(u1, caller_pid: self(), timeout_ms: 5_000)
    {:ok, :unido} = GestorSalas.unirse_sala_intercambio(room_id, u2, self())

    assert {:ok, %{ofrecido: ^id1}} = GestorSalas.ofrecer_pokemon_intercambio(room_id, u1, id1)
    assert {:ok, %{ofrecido: ^id2}} = GestorSalas.ofrecer_pokemon_intercambio(room_id, u2, id2)

    assert {:ok, _} = GestorSalas.confirmar_intercambio(room_id, u1)
    assert {:ok, %{intercambiado: true}} = GestorSalas.confirmar_intercambio(room_id, u2)

    inst1 = Persistencia.obtener_instancia(id1)
    inst2 = Persistencia.obtener_instancia(id2)

    assert inst1["dueño_original"] == u1
    assert inst2["dueño_original"] == u2

    {:ok, ids_u1} = Persistencia.inventario_pokemon(u1)
    {:ok, ids_u2} = Persistencia.inventario_pokemon(u2)

    assert id1 not in ids_u1
    assert id2 in ids_u1
    assert id2 not in ids_u2
    assert id1 in ids_u2
  end
end

