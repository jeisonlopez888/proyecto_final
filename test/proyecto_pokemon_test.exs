defmodule ProyectoPokemonTest do
  use ExUnit.Case
  doctest ProyectoPokemon

  test "greets the world" do
    assert ProyectoPokemon.hello() == :world
  end
end
