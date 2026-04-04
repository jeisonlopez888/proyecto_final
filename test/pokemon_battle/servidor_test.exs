defmodule PokemonBattle.ServidorTest do
  @moduledoc false

  use ExUnit.Case, async: false

  @tag :requisito_consola
  test "requisito: interfaz de consola (Servidor) — login y perfil" do
    u = "consola_#{System.unique_integer([:positive])}"

    assert {:ok, msg} = PokemonBattle.Servidor.comando("iniciar #{u} mi_clave_123")
    assert String.contains?(msg, u)

    assert {:ok, perfil} = PokemonBattle.Servidor.comando("perfil")
    assert String.contains?(perfil, u)
    assert String.contains?(perfil, "Monedas")

    assert {:ok, _} = PokemonBattle.Servidor.comando("salir")
  end
end
