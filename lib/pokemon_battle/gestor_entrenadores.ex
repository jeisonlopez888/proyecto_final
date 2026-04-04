defmodule PokemonBattle.GestorEntrenadores do
  @moduledoc """
  Lógica de entrenadores:

  - Login (`iniciar`)
  - Perfil e inventario
  - Clasificación
  - Equipos: `crear_equipo` y `usar_equipo`
  """

  alias PokemonBattle.Persistencia

  @free_pack_count 1

  @doc """
  Inicia sesión con `usuario` y `clave`.

  - Si el entrenador no existe, se auto-registra.
  - Al registrarse se otorga `1` sobre gratis.
  """
  def iniciar(usuario, clave) do
    usuario = to_string(usuario)
    clave = to_string(clave)

    case Persistencia.obtener_entrenador(usuario) do
      nil ->
        # Registro automático.
        Persistencia.guardar_entrenador(usuario, %{
          "clave" => clave,
          "monedas" => 0,
          "monedas_acumuladas" => 0,
          "historial" => [],
          "inventario_pokemon_ids" => [],
          "sobres_sin_abrir" => @free_pack_count,
          "cola_sobres" => List.duplicate("sobre_basico", @free_pack_count),
          "equipos" => %{},
          "equipo_activo" => nil,
          "victorias" => 0,
          "derrotas" => 0
        })

        {:ok, Persistencia.obtener_entrenador(usuario)}

      trainer ->
        stored_hash = trainer["clave_hash"]

        if Persistencia.verificar_clave?(clave, stored_hash) do
          {:ok, trainer}
        else
          {:error, :clave_incorrecta}
        end
    end
  end

  @doc "Devuelve el perfil del entrenador (map con datos persistidos)."
  def perfil(usuario) do
    usuario = to_string(usuario)
    Persistencia.obtener_entrenador(usuario) || {:error, :no_existe}
  end

  @doc """
  Devuelve el inventario del entrenador: lista de IDs + instancias completas.
  """
  def inventario(usuario) do
    usuario = to_string(usuario)

    with {:ok, ids} <- {:ok, get_inventario_ids(usuario)},
         instancias <- Enum.map(ids, &Persistencia.obtener_instancia/1),
         instancias2 = Enum.filter(instancias, &(&1 != nil)) do
      {:ok, %{pokemon_ids: ids, pokemon: instancias2}}
    else
      _ -> {:error, :no_existe}
    end
  end

  defp get_inventario_ids(usuario) do
    case Persistencia.inventario_pokemon(usuario) do
      {:ok, ids} -> ids
      _ -> []
    end
  end

  @doc """
  Devuelve clasificación ordenada por un puntaje (monedas + victorias).
  """
  def clasificacion() do
    trainers = Persistencia.listar_entrenadores()

    puntuados =
      trainers
      |> Map.to_list()
      |> Enum.map(fn {usuario, data} ->
        victorias = data["victorias"] || 0
        monedas_actuales = data["monedas"] || 0
        monedas_acumuladas = data["monedas_acumuladas"] || 0

        {usuario,
         %{
           monedas: monedas_actuales,
           monedas_acumuladas: monedas_acumuladas,
           victorias: victorias
         }}
      end)
      |> Enum.sort_by(fn {_u, meta} ->
        {-meta.victorias, -meta.monedas_acumuladas}
      end)

    {:ok, Enum.map(puntuados, fn {u, meta} -> Map.put(meta, :usuario, u) end)}
  end

  # =========================
  # Equipos
  # =========================

  @doc "Crea un equipo (1 a 3 Pokémon) con nombre único para el usuario."
  def crear_equipo(usuario, nombre, pokemon_ids) do
    usuario = to_string(usuario)
    nombre = to_string(nombre)
    ids = Enum.map(pokemon_ids, &normalize_int_id/1)
    Persistencia.guardar_equipo(usuario, nombre, ids)
  end

  def listar_equipos(usuario) do
    case Persistencia.listar_equipos(usuario) do
      {:ok, map} -> {:ok, map}
      err -> err
    end
  end

  def quitar_pokemon_equipo(usuario, nombre_equipo, pokemon_id) do
    Persistencia.equipo_quitar_pokemon(usuario, nombre_equipo, pokemon_id)
  end

  def agregar_pokemon_equipo(usuario, nombre_equipo, pokemon_id) do
    Persistencia.equipo_agregar_pokemon(usuario, nombre_equipo, pokemon_id)
  end

  @doc "Selecciona un equipo previamente creado como `equipo_activo`."
  def usar_equipo(usuario, nombre_equipo) do
    usuario = to_string(usuario)
    nombre_equipo = to_string(nombre_equipo)

    trainer = Persistencia.obtener_entrenador(usuario)
    if trainer == nil do
      {:error, :no_existe}
    else
      equipos = trainer["equipos"] || %{}

      if Map.has_key?(equipos, nombre_equipo) do
        Persistencia.guardar_entrenador(usuario, %{
          "equipo_activo" => nombre_equipo
        })

        {:ok, nombre_equipo}
      else
        {:error, :equipo_inexistente}
      end
    end
  end

  # =========================
  # Helpers
  # =========================

  defp normalize_int_id(id) when is_integer(id), do: id
  defp normalize_int_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> String.to_integer(id)
    end
  end
end

