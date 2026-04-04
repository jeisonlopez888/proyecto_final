defmodule PokemonBattle.MotorCombateTest do
  use ExUnit.Case, async: false

  alias PokemonBattle.MotorCombate

  test "efectividad: fuego > planta (x2), planta ataca a fuego (x0.5)" do
    assert MotorCombate.efectividad_un_tipo("fuego", "planta") == 2.0
    assert MotorCombate.efectividad_un_tipo("planta", "fuego") == 0.5
  end

  test "doble tipo: multiplica efectividades (ej. eléctrico vs agua/volador)" do
    assert MotorCombate.efectividad_total("electrico", ["agua", "volador"]) == 4.0
  end

  test "daño correcto según fórmula exacta" do
    # dano_base  = trunc((poder * (ataque / defensa)) / 5 + 2)
    # dano_final = trunc(dano_base * efectividad * stab * random)
    # con:
    # poder=100, ataque=50, defensa=25 => (100*(50/25))/5 +2 = (100*2)/5+2 = 40+2 = 42
    # dano_final = trunc(42 * 2.0 * 1.5 * 1.0) = trunc(126) = 126
    dano = MotorCombate.calcular_dano(100, 50, 25, 2.0, 1.5, 1.0)
    assert dano == 126
  end
end

