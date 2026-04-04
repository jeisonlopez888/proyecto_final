defmodule PokemonBattle.PersistenciaTest do
  use ExUnit.Case, async: false

  describe "hash de contraseña" do
    test "verificar_clave? acierta con la misma clave" do
      h = PokemonBattle.Persistencia.hash_clave("secreto")
      assert PokemonBattle.Persistencia.verificar_clave?("secreto", h)
      refute PokemonBattle.Persistencia.verificar_clave?("otro", h)
    end
  end

  describe "instancias Pokémon" do
    test "crear_instancia_pokemon asigna id incremental y persiste" do
      assert {:ok, id} =
               PokemonBattle.Persistencia.crear_instancia_pokemon(%{
                 "especie" => "pikachu",
                 "dueño_original" => "alice",
                 "rareza" => "comun",
                 "ataque" => 10,
                 "defensa" => 10,
                 "velocidad" => 10,
                 "movimientos" => ["a", "b", "c", "d"]
               })

      inst = PokemonBattle.Persistencia.obtener_instancia(id)
      assert inst["especie"] == "pikachu"
      assert inst["id"] == id

      path = Path.join(PokemonBattle.Persistencia.data_dir(), "pokemon.json")
      assert File.exists?(path)
      contenido = File.read!(path)
      assert String.contains?(contenido, "pikachu")
    end
  end

  describe "entrenador e inventario" do
    test "guardar entrenador y agregar al inventario" do
      u = "trainer_test_#{System.unique_integer([:positive])}"

      :ok =
        PokemonBattle.Persistencia.guardar_entrenador(u, %{
          "clave" => "x",
          "monedas" => 100
        })

      assert %{"monedas" => 100} = PokemonBattle.Persistencia.obtener_entrenador(u)

      assert {:ok, pid} =
               PokemonBattle.Persistencia.crear_instancia_pokemon(%{
                 "especie" => "rattata",
                 "dueño_original" => u,
                 "rareza" => "comun",
                 "ataque" => 5,
                 "defensa" => 5,
                 "velocidad" => 5,
                 "movimientos" => ["m1", "m2", "m3", "m4"]
               })

      assert :ok = PokemonBattle.Persistencia.agregar_al_inventario(u, pid)
      assert {:ok, ids} = PokemonBattle.Persistencia.inventario_pokemon(u)
      assert pid in ids
    end
  end
end
