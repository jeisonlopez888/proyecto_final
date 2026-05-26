defmodule PokemonBattle.GestorEntrenadores do
  @moduledoc """
  **Reglas de negocio** del entrenador por encima de `Persistencia`.

  Aquí se implementa lo que el jugador percibe como cuenta: inicio de sesión y registro,
  consulta de perfil e inventario con instancias resueltas, clasificación global
  y gestión de equipos (crear, listar, modificar, marcar equipo activo para batallas).
  Todas las operaciones delegan en `PokemonBattle.Persistencia` para mantener datos coherentes en disco.
  """

  alias PokemonBattle.Persistencia

  @doc """
  Inicia sesión con `usuario` y `clave`.

  - Si el entrenador no existe, se auto-registra y recibe un sobre básico gratis
    (ver `Persistencia` al crear el perfil).
  - Devuelve `{:ok, entrenador, :registrado}` en el primer alta o `{:ok, entrenador, :existente}` si ya existía.
  """
  def iniciar(usuario, clave) do
    usuario = to_string(usuario)
    clave = to_string(clave)

    case Persistencia.obtener_entrenador(usuario) do
      nil ->
        Persistencia.guardar_entrenador(usuario, %{
          "clave" => clave,
          "monedas" => 0,
          "monedas_acumuladas" => 0,
          "historial" => [],
          "inventario_pokemon_ids" => [],
          "equipos" => %{},
          "equipo_activo" => nil,
          "victorias" => 0,
          "derrotas" => 0
        })

        {:ok, Persistencia.obtener_entrenador(usuario), :registrado}

      trainer ->
        stored_hash = trainer["clave_hash"]

        if Persistencia.verificar_clave?(clave, stored_hash) do
          {:ok, trainer, :existente}
        else
          {:error, :clave_incorrecta}
        end
    end
  end

  @doc """
  Devuelve el mapa completo del entrenador tal como está en persistencia, o `{:error, :no_existe}`.
  Sirve para mostrar monedas, victorias, inventario en bruto, etc.
  """
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
  Construye la tabla de clasificación: lista ordenada primero por **victorias** (descendente)
  y luego por **monedas acumuladas** (histórico de ganancias, descendente).
  Cada fila incluye `:usuario`, `:monedas`, `:monedas_acumuladas` y `:victorias`.
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

  @doc """
  Crea o sustituye un equipo con nombre único para ese usuario, con entre 1 y 3 Pokémon cuyos IDs estén en su inventario.
  """
  def crear_equipo(usuario, nombre, pokemon_ids) do
    usuario = to_string(usuario)
    nombre = to_string(nombre)
    ids = Enum.map(pokemon_ids, &normalize_int_id/1)
    Persistencia.guardar_equipo(usuario, nombre, ids)
  end

  @doc """
  Devuelve `{:ok, mapa_de_equipos}` donde cada clave es el nombre del equipo y el valor es la lista de IDs de instancia.
  """
  def listar_equipos(usuario) do
    case Persistencia.listar_equipos(usuario) do
      {:ok, map} -> {:ok, map}
      err -> err
    end
  end

  @doc """
  Quita un Pokémon de un equipo guardado sin borrarlo del inventario. El equipo no puede quedar vacío.
  """
  def quitar_pokemon_equipo(usuario, nombre_equipo, pokemon_id) do
    Persistencia.equipo_quitar_pokemon(usuario, nombre_equipo, pokemon_id)
  end

  @doc """
  Añade al equipo un Pokémon que ya esté en el inventario, si el equipo tiene menos de 3 miembros y no está duplicado.
  """
  def agregar_pokemon_equipo(usuario, nombre_equipo, pokemon_id) do
    Persistencia.equipo_agregar_pokemon(usuario, nombre_equipo, pokemon_id)
  end

  @doc """
  Marca un equipo guardado como **equipo activo** (`equipo_activo` en el perfil). Ese equipo se usará al unirse a una sala de batalla.
  """
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

