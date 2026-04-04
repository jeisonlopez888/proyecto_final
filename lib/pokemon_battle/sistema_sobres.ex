defmodule PokemonBattle.SistemaSobres do
  @moduledoc """
  **Tienda de sobres** y apertura de paquetes.

  - La compra descuenta monedas, valida el tipo de sobre contra `tienda.json` y **encola** el sobre (FIFO).
  - Al abrir, se saca el siguiente sobre de la cola, se tiran probabilidades de rareza según ese tipo
    y se generan 3 instancias nuevas con stats y 4 movimientos acordes a la especie y al catálogo de movimientos.
  Las instancias se guardan en persistencia y se añaden al inventario del jugador.
  """

  alias PokemonBattle.Persistencia

  @doc """
  Devuelve `{:ok, catálogo}` con el contenido de `tienda.json` (precios y pesos de rareza por clave de sobre).
  """
  def tienda(), do: {:ok, Persistencia.catalogo_tienda()}

  @doc """
  Compra un sobre del tipo indicado (`tipo` o `sobre_basico`, etc.). Cobra el precio, hace `push` en la cola de sobres
  y devuelve `{:ok, %{sobre: clave, precio: ...}}` o error si el sobre no existe o no hay saldo.
  """
  def comprar_sobre(usuario, tipo) do
    usuario = to_string(usuario)
    clave = normalizar_tipo_sobre(tipo)

    tienda = Persistencia.catalogo_tienda()
    sobre = tienda[clave]

    if is_nil(sobre) do
      {:error, :sobre_inexistente}
    else
      precio = sobre["precio"] || 0

      with {:ok, _monedas} <- Persistencia.ajustar_monedas(usuario, -precio),
           :ok <- Persistencia.push_sobre_cola(usuario, clave) do
        {:ok, %{sobre: clave, precio: precio}}
      end
    end
  end

  @doc """
  Abre el **siguiente** sobre en cola para el usuario (el parámetro extra se ignora; reservado por compatibilidad).
  Genera 3 Pokémon, los persiste y devuelve `{:ok, %{pokemon_ids: ids, pokemon: instancias}}` o error si la cola está vacía.
  """
  def abrir_sobre(usuario, _id_o_ultimo \\ "ultimo") do
    usuario = to_string(usuario)

    with {:ok, clave_sobre} <- Persistencia.pop_sobre_cola(usuario),
         ids <- generar_y_guardar_pokemon(usuario, 3, clave_sobre) do
      {:ok, %{pokemon_ids: ids, pokemon: Enum.map(ids, &Persistencia.obtener_instancia/1)}}
    else
      {:error, _} = err -> err
    end
  end

  # --- Generación ---

  defp generar_y_guardar_pokemon(usuario, cantidad, clave_sobre) when cantidad > 0 do
    especie_catalogo = Persistencia.catalogo_especies()
    moves = Persistencia.catalogo_movimientos()
    por_tipo = moves["por_tipo"] || %{}
    globales = moves["globales"] || []
    especies = Map.keys(especie_catalogo)

    Enum.map(1..cantidad, fn _ ->
      especie = Enum.random(especies)
      especie_data = especie_catalogo[especie]
      rareza = seleccionar_rareza(clave_sobre)

      factor = factor_rareza_pct(rareza)

      base_a = especie_data["base_ataque"] || especie_data["ataque_base"] || 0
      base_d = especie_data["base_defensa"] || especie_data["defensa_base"] || 0
      base_v = especie_data["base_velocidad"] || especie_data["velocidad_base"] || 0

      ataque = round(base_a * (1 + factor / 100))
      defensa = round(base_d * (1 + factor / 100))
      velocidad = round(base_v * (1 + factor / 100))

      movimientos = generar_movimientos(especie_data, por_tipo, globales)

      {:ok, id} =
        Persistencia.crear_instancia_pokemon(%{
          "especie" => especie,
          "dueño_original" => usuario,
          "rareza" => rareza,
          "ataque" => ataque,
          "defensa" => defensa,
          "velocidad" => velocidad,
          "movimientos" => movimientos
        })

      :ok = Persistencia.agregar_al_inventario(usuario, id)
      id
    end)
  end

  defp factor_rareza_pct("comun"), do: :rand.uniform(7) + 1
  defp factor_rareza_pct("raro"), do: :rand.uniform(11) + 9
  defp factor_rareza_pct("epico"), do: :rand.uniform(16) + 24
  defp factor_rareza_pct(_), do: 5

  defp seleccionar_rareza(clave_sobre) do
    tienda = Persistencia.catalogo_tienda()
    sobre = tienda[clave_sobre] || %{}

    c = sobre["comun"] || 70
    r = sobre["raro"] || 25
    e = sobre["epico"] || 5
    t = c + r + e
    x = if t > 0, do: :rand.uniform(t), else: :rand.uniform(100)

    cond do
      x <= c -> "comun"
      x <= c + r -> "raro"
      true -> "epico"
    end
  end

  defp tipos_especie(especie_data) do
    cond do
      is_list(especie_data["tipos"]) ->
        especie_data["tipos"]

      is_binary(especie_data["tipo"]) && String.contains?(especie_data["tipo"], "/") ->
        especie_data["tipo"] |> String.split("/") |> Enum.map(&String.trim/1)

      especie_data["tipo"] ->
        [especie_data["tipo"]]

      true ->
        ["normal"]
    end
  end

  defp generar_movimientos(especie_data, por_tipo, globales) do
    tipos = tipos_especie(especie_data)
    glob = globales ++ Enum.flat_map(Map.values(por_tipo), & &1)

    todos_por_id = Enum.uniq_by(glob, & &1["id"])

    elegidos =
      case tipos do
        [t1] ->
          pool1 = movimientos_de_tipo(t1, por_tipo, globales)
          t1_ids = tomar_distintos_random(pool1, 2)

          resto_pool = Enum.reject(todos_por_id, fn m -> m["id"] in t1_ids end)
          resto_ids = tomar_distintos_random(resto_pool, 2)
          t1_ids ++ resto_ids

        [t1, t2 | _] ->
          p1 = movimientos_de_tipo(t1, por_tipo, globales)
          p2 = movimientos_de_tipo(t2, por_tipo, globales)
          a = tomar_distintos_random(p1, 1)
          b = tomar_distintos_random(p2, 1)
          usados = a ++ b

          resto_pool = Enum.reject(todos_por_id, fn m -> m["id"] in usados end)
          resto_ids = tomar_distintos_random(resto_pool, 4 - length(usados))
          usados ++ resto_ids

        _ ->
          tomar_distintos_random(todos_por_id, 4)
      end

    if length(elegidos) != 4 or length(Enum.uniq(elegidos)) != 4 do
      raise "generación de movimientos inválida"
    end

    elegidos
  end

  defp movimientos_de_tipo(tipo, por_tipo, globales) do
    t = to_string(tipo)
    base = por_tipo[t] || []
    extra = Enum.filter(globales, fn m -> to_string(m["tipo"]) == t end)
    Enum.uniq_by(base ++ extra, & &1["id"])
  end

  defp tomar_distintos_random(_lista, cantidad) when cantidad <= 0, do: []

  defp tomar_distintos_random(lista, cantidad) do
    lista = Enum.uniq_by(lista, & &1["id"])

    if length(lista) < cantidad do
      raise "pool insuficiente para #{cantidad} movimientos"
    end

    Enum.take_random(lista, cantidad) |> Enum.map(& &1["id"])
  end

  defp normalizar_tipo_sobre(tipo) do
    tipo = tipo |> to_string() |> String.downcase() |> String.trim()

    cond do
      String.starts_with?(tipo, "sobre_") -> tipo
      true -> "sobre_" <> tipo
    end
  end
end
