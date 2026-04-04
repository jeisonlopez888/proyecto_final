defmodule PokemonBattle.MotorCombate do
  @moduledoc """
  Motor de cálculo de daño para batallas Pokémon.

  Fórmula (enunciado §7.6):

  `dano_base  = trunc((poder * (ataque / defensa)) / 5 + 2)`
  `dano_final = trunc(dano_base * efectividad * stab * factor_aleatorio)`

  Efectividad: tabla §3.3; si el defensor tiene 2 tipos, se multiplican los
  modificadores de cada uno. STAB si el tipo del movimiento coincide con algún
  tipo de la especie atacante.
  """

  @default_random_min 0.85
  @default_random_max 1.0

  @doc """
  Normaliza nombres de tipo para comparación (minúsculas, sin acentos comunes).
  """
  def normalizar_tipo(t) do
    t
    |> to_string()
    |> String.downcase()
    |> String.trim()
    |> String.replace("é", "e")
    |> String.replace("á", "a")
    |> String.replace("í", "i")
    |> String.replace("ó", "o")
    |> String.replace("ú", "u")
  end

  @doc """
  ¿El tipo atacante (movimiento) es fuerte contra el tipo defensor? (×2)
  Tabla mínima §3.3.
  """
  def fuerte_contra?(tipo_ataque, tipo_defensa) do
    a = normalizar_tipo(tipo_ataque)
    d = normalizar_tipo(tipo_defensa)

    case a do
      "fuego" -> d in ["planta", "hielo", "bicho"]
      "agua" -> d in ["fuego", "roca", "tierra"]
      "planta" -> d in ["agua", "roca", "tierra"]
      "electrico" -> d in ["agua", "volador"]
      "roca" -> d in ["fuego", "hielo", "volador", "bicho"]
      _ -> false
    end
  end

  @doc """
  Modificador de efectividad de un movimiento de tipo `tipo_mov` contra
  un defensor con un solo tipo `tipo_def`.
  """
  def efectividad_un_tipo(tipo_mov, tipo_def) do
    tm = normalizar_tipo(tipo_mov)
    td = normalizar_tipo(tipo_def)

    cond do
      fuerte_contra?(tm, td) -> 2.0
      fuerte_contra?(td, tm) -> 0.5
      true -> 1.0
    end
  end

  @doc """
  Producto de efectividades contra cada tipo del defensor (doble tipo).
  """
  def efectividad_total(tipo_mov, tipos_defensor) when is_list(tipos_defensor) do
    tipos_defensor
    |> Enum.map(&efectividad_un_tipo(tipo_mov, &1))
    |> Enum.reduce(1.0, &Kernel.*/2)
  end

  def efectividad_total(tipo_mov, tipo_def) when is_binary(tipo_def) do
    efectividad_un_tipo(tipo_mov, tipo_def)
  end

  @doc """
  STAB = 1.5 si el tipo del movimiento coincide con algún tipo del atacante.
  """
  def stab(tipo_mov, tipos_atacante) when is_list(tipos_atacante) do
    tm = normalizar_tipo(tipo_mov)

    if Enum.any?(tipos_atacante, &(normalizar_tipo(&1) == tm)),
      do: 1.5,
      else: 1.0
  end

  def stab(tipo_mov, tipo_atacante) when is_binary(tipo_atacante) do
    stab(tipo_mov, [tipo_atacante])
  end

  @spec calcular_dano(integer(), integer(), integer(), float(), float(), float()) :: integer()
  def calcular_dano(poder, ataque, defensa, efectividad, stab_val, random_factor)
      when is_integer(poder) and is_integer(ataque) and is_integer(defensa) do
    defensa_i = max(defensa, 1)

    dano_base =
      trunc(((poder * (ataque / defensa_i)) / 5) + 2)

    dano_final = trunc(dano_base * efectividad * stab_val * random_factor)
    max(dano_final, 1)
  end

  def random_factor(min \\ @default_random_min, max \\ @default_random_max)
      when is_float(min) and is_float(max) and min <= max do
    r = :rand.uniform()
    min + (r * (max - min))
  end

  @doc """
  Calcula el daño de un movimiento.

  `atacante` y `defensor` deben incluir:
  - `\"tipos\"` — lista de tipos de la especie (puede ser un solo elemento), o
  - `\"tipo\"` — string (compatibilidad)
  """
  def calcular_dano_movimiento(mov, atacante, defensor, opts \\ []) when is_map(mov) do
    poder = mov["poder"] || 0
    tipo_mov = mov["tipo"] || "normal"

    ataque = atacante["ataque"] || 0
    defensa = defensor["defensa"] || 1

    tipos_def = tipos_desde_map(defensor)
    tipos_atk = tipos_desde_map(atacante)

    efect = efectividad_total(tipo_mov, tipos_def)
    stab_val = stab(tipo_mov, tipos_atk)

    random_f =
      case Keyword.get(opts, :random_factor) do
        nil -> random_factor()
        x when is_float(x) -> x
        x when is_integer(x) -> x * 1.0
      end

    calcular_dano(poder, ataque, defensa, efect, stab_val, random_f)
  end

  defp tipos_desde_map(map) do
    case map["tipos"] do
      list when is_list(list) -> list
      nil -> [map["tipo"] || "normal"]
      other -> [other]
    end
  end
end
