defmodule PokemonBattle.NodoEntrenadorTest do
  use ExUnit.Case, async: true

  alias PokemonBattle.NodoEntrenador

  test "slug_entrenador normaliza nombres" do
    assert {:ok, "ana"} = NodoEntrenador.slug_entrenador("Ana")
    assert {:ok, "luis_garcia"} = NodoEntrenador.slug_entrenador("Luis Garcia")
    assert {:error, :usuario_invalido} = NodoEntrenador.slug_entrenador("   ")
    assert {:error, :usuario_invalido} = NodoEntrenador.slug_entrenador("123")
  end

  test "nodo_atom usa host 127.0.0.1 por defecto" do
    assert NodoEntrenador.nodo_atom("ana") == :"ana@127.0.0.1"
  end
end
