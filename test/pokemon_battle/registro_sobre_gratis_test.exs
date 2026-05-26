defmodule PokemonBattle.RegistroSobreGratisTest do
  use ExUnit.Case, async: false

  alias PokemonBattle.GestorEntrenadores
  alias PokemonBattle.Persistencia
  alias PokemonBattle.SistemaSobres

  test "al registrarse un entrenador nuevo recibe un sobre básico gratis y puede abrirlo" do
    u = "registro_#{System.unique_integer([:positive])}"

    assert {:ok, trainer, :registrado} = GestorEntrenadores.iniciar(u, "clave123")
    assert trainer["sobres_sin_abrir"] == 1
    assert trainer["cola_sobres"] == ["sobre_basico"]

    assert {:ok, %{pokemon_ids: ids}} = SistemaSobres.abrir_sobre(u, "ultimo")
    assert length(ids) == 3

    trainer2 = Persistencia.obtener_entrenador(u)
    assert trainer2["sobres_sin_abrir"] == 0
    assert trainer2["cola_sobres"] == []
  end

  test "un inicio de sesión posterior no otorga otro sobre gratis" do
    u = "registro2_#{System.unique_integer([:positive])}"

    assert {:ok, _, :registrado} = GestorEntrenadores.iniciar(u, "clave123")
    assert {:ok, trainer, :existente} = GestorEntrenadores.iniciar(u, "clave123")
    assert trainer["sobres_sin_abrir"] == 1
  end

  test "guardar entrenador nuevo sin sobres en attrs recibe el sobre de registro" do
    u = "persist_#{System.unique_integer([:positive])}"

    :ok = Persistencia.guardar_entrenador(u, %{"clave" => "x", "monedas" => 0})

    assert %{"sobres_sin_abrir" => 1, "cola_sobres" => ["sobre_basico"]} =
             Persistencia.obtener_entrenador(u)
  end
end
