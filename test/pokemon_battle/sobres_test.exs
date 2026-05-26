defmodule PokemonBattle.SobresTest do
  use ExUnit.Case, async: false

  alias PokemonBattle.GestorEntrenadores
  alias PokemonBattle.SistemaSobres
  alias PokemonBattle.Persistencia

  defp nuevo_usuario(base) do
    "#{base}_#{System.unique_integer([:positive])}"
  end

  test "sobres generan Pokémon válidos (3 por sobre, rareza permitida, 4 movimientos sin repetir y al menos 2 del tipo)" do
    :rand.seed(:exsplus, {10, 20, 30})

    u = nuevo_usuario("sobres")
    {:ok, _, :registrado} = GestorEntrenadores.iniciar(u, "clave")

    {:ok, %{pokemon_ids: ids}} = SistemaSobres.abrir_sobre(u, "ultimo")
    assert length(ids) == 3

    especies = Persistencia.catalogo_especies()
    movimientos = Persistencia.catalogo_movimientos()
    tipo_por_especie = especies

    # Índice movimiento_id => movimiento(map)
    por_tipo = movimientos["por_tipo"] || %{}
    globales = movimientos["globales"] || []
    todos = por_tipo |> Map.values() |> List.flatten() |> Kernel.++(globales)
    moves_index = Map.new(todos, fn m -> {m["id"], m} end)

    for id <- ids do
      inst = Persistencia.obtener_instancia(id)
      assert inst["dueño_original"] == u
      assert inst["especie"] in Map.keys(especies)

      rareza = inst["rareza"]
      assert rareza in ["comun", "raro", "epico"]

      assert is_integer(inst["ataque"]) and inst["ataque"] > 0
      assert is_integer(inst["defensa"]) and inst["defensa"] > 0
      assert is_integer(inst["velocidad"]) and inst["velocidad"] > 0

      movs = inst["movimientos"]
      assert length(movs) == 4
      assert length(Enum.uniq(movs)) == 4
      assert Enum.all?(movs, &Map.has_key?(moves_index, &1))

      ed = tipo_por_especie[inst["especie"]]

      tipos_esp =
        cond do
          is_list(ed["tipos"]) -> ed["tipos"]
          is_binary(ed["tipo"]) && String.contains?(ed["tipo"], "/") ->
            String.split(ed["tipo"], "/") |> Enum.map(&String.trim/1)

          ed["tipo"] ->
            [ed["tipo"]]

          true ->
            ["normal"]
        end

      ts = Enum.map(tipos_esp, &to_string/1)

      cuenta_tipo =
        movs
        |> Enum.map(fn mid -> moves_index[mid] end)
        |> Enum.count(fn m -> to_string(m["tipo"]) in ts end)

      assert cuenta_tipo >= 2
    end
  end
end

