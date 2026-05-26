defmodule PokemonBattle.BatallaTest do
  use ExUnit.Case, async: false

  alias PokemonBattle.GestorEntrenadores
  alias PokemonBattle.GestorSalas
  alias PokemonBattle.Persistencia

  defp nuevo_usuario(base) do
    "#{base}_#{System.unique_integer([:positive])}"
  end

  defp crear_pokemon_instancia(usuario, especie, stats, movimientos, rareza \\ "comun") do
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

  defp preparar_equipo(usuario, nombre, pokemon_id) do
    :ok = GestorEntrenadores.crear_equipo(usuario, nombre, [pokemon_id])
    {:ok, _} = GestorEntrenadores.usar_equipo(usuario, nombre)
  end

  test "orden por velocidad (turno resuelto por quien es más rápido)" do
    :rand.seed(:exsplus, {1, 2, 3})

    u1 = nuevo_usuario("ana")
    u2 = nuevo_usuario("luis")

    {:ok, _, _} = GestorEntrenadores.iniciar(u1, "1234")
    {:ok, _, _} = GestorEntrenadores.iniciar(u2, "1234")

    # Alta velocidad vs baja velocidad
    id1 = crear_pokemon_instancia(u1, "pikachu", %{ataque: 50, defensa: 300, velocidad: 100}, ["impactrueno", "rayo", "Destructor", "Hiperrayo"])
    id2 = crear_pokemon_instancia(u2, "squirtle", %{ataque: 40, defensa: 300, velocidad: 10}, ["hidrobomba", "pistola_agua", "Destructor", "Hiperrayo"])

    preparar_equipo(u1, "equipo_1", id1)
    preparar_equipo(u2, "equipo_2", id2)

    {:ok, room_id} = GestorSalas.crear_sala(u1, caller_pid: self(), random_factor: 1.0)
    :ok = GestorSalas.unirse_sala(room_id, u2, self()) |> case do
      {:ok, :unido} -> :ok
      other -> other
    end

    {:ok, _} = GestorSalas.iniciar_batalla(room_id, u1)

    # Acciones "simultáneas": enviamos primero la de u1 y luego la de u2.
    assert {:ok, :esperando_oponente} = GestorSalas.ataque(room_id, u1, "rayo")
    assert {:ok, _meta} = GestorSalas.ataque(room_id, u2, "hidrobomba")

    assert GestorSalas.obtener_ultimo_orden(room_id) == [u1, u2]
  end

  test "monedas después de rendirse (recompensa y penalización)" do
    u1 = nuevo_usuario("victor")
    u2 = nuevo_usuario("perdedor")

    {:ok, _, _} = GestorEntrenadores.iniciar(u1, "1234")
    {:ok, _, _} = GestorEntrenadores.iniciar(u2, "1234")

    # Ajustamos monedas para test estable.
    {:ok, _} = Persistencia.ajustar_monedas(u1, 200)
    {:ok, _} = Persistencia.ajustar_monedas(u2, 200)

    id1 = crear_pokemon_instancia(u1, "bulbasaur", %{ataque: 80, defensa: 120, velocidad: 30}, ["rayo_solar", "latigo_cepa", "Destructor", "Hiperrayo"])
    id2 = crear_pokemon_instancia(u2, "charmander", %{ataque: 70, defensa: 120, velocidad: 25}, ["llama", "ascuas", "Destructor", "Hiperrayo"])

    preparar_equipo(u1, "equipo_1", id1)
    preparar_equipo(u2, "equipo_2", id2)

    {:ok, room_id} = GestorSalas.crear_sala(u1, random_factor: 1.0)
    {:ok, :unido} = GestorSalas.unirse_sala(room_id, u2, self())
    {:ok, _} = GestorSalas.iniciar_batalla(room_id, u1)

    assert {:ok, %{ganador: ^u1}} = GestorSalas.rendirse(room_id, u2)

    t1 = Persistencia.obtener_entrenador(u1)
    t2 = Persistencia.obtener_entrenador(u2)

    assert t1["monedas"] == 300
    assert t2["monedas"] == 230
  end

  @tag :requisito_paralelo
  test "requisito: varias batallas en paralelo (dos salas independientes)" do
    :rand.seed(:exsplus, {7, 8, 9})

    u1a = nuevo_usuario("p1a")
    u1b = nuevo_usuario("p1b")
    u2a = nuevo_usuario("p2a")
    u2b = nuevo_usuario("p2b")

    for u <- [u1a, u1b, u2a, u2b] do
      {:ok, _, _} = GestorEntrenadores.iniciar(u, "1234")
    end

    # Sala 1: u1a rápido, u1b lento
    id1a = crear_pokemon_instancia(u1a, "pikachu", %{ataque: 50, defensa: 300, velocidad: 90}, ["impactrueno", "rayo", "Destructor", "Hiperrayo"])
    id1b = crear_pokemon_instancia(u1b, "squirtle", %{ataque: 40, defensa: 300, velocidad: 5}, ["hidrobomba", "pistola_agua", "Destructor", "Hiperrayo"])

    # Sala 2: u2a lento, u2b rápido (orden de actuación distinto al de sala 1)
    id2a = crear_pokemon_instancia(u2a, "bulbasaur", %{ataque: 40, defensa: 300, velocidad: 5}, ["latigo_cepa", "rayo_solar", "Destructor", "Hiperrayo"])
    id2b = crear_pokemon_instancia(u2b, "charmander", %{ataque: 50, defensa: 300, velocidad: 90}, ["llama", "ascuas", "Destructor", "Hiperrayo"])

    preparar_equipo(u1a, "e1a", id1a)
    preparar_equipo(u1b, "e1b", id1b)
    preparar_equipo(u2a, "e2a", id2a)
    preparar_equipo(u2b, "e2b", id2b)

    {:ok, r1} = GestorSalas.crear_sala(u1a, caller_pid: self(), random_factor: 1.0)
    {:ok, r2} = GestorSalas.crear_sala(u2a, caller_pid: self(), random_factor: 1.0)

    assert r1 != r2

    {:ok, :unido} = GestorSalas.unirse_sala(r1, u1b, self())
    {:ok, :unido} = GestorSalas.unirse_sala(r2, u2b, self())

    {:ok, _} = GestorSalas.iniciar_batalla(r1, u1a)
    {:ok, _} = GestorSalas.iniciar_batalla(r2, u2a)

    assert {:ok, :esperando_oponente} = GestorSalas.ataque(r1, u1a, "rayo")
    assert {:ok, :esperando_oponente} = GestorSalas.ataque(r2, u2a, "latigo_cepa")

    assert {:ok, _m1} = GestorSalas.ataque(r1, u1b, "hidrobomba")
    assert {:ok, _m2} = GestorSalas.ataque(r2, u2b, "llama")

    assert GestorSalas.obtener_ultimo_orden(r1) == [u1a, u1b]
    assert GestorSalas.obtener_ultimo_orden(r2) == [u2b, u2a]
  end
end

