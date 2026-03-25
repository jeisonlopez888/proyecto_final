defmodule PokemonBattle.Persistencia do
  @moduledoc """
  Capa de persistencia basada en JSON con guardado automático tras cada cambio.

  Gestiona:
  - **Entrenadores**: credenciales (hash), monedas, historial.
  - **Inventario**: IDs de instancias de Pokémon poseídas por cada usuario.
  - **Sobres**: contador de sobres sin abrir por entrenador.
  - **Equipos**: nombres únicos por usuario, 1–3 Pokémon (IDs de instancia).
  - **Instancias de Pokémon** y catálogo de especies (solo en `pokemon.json`).
  - Catálogo de movimientos y precios de tienda.

  Implementación: un `GenServer` serializa escrituras y evita corrupción de datos;
  cada mutación vuelca a disco de forma atómica (archivo temporal + renombrado).

  **Decisión de diseño**: las claves en memoria y en JSON son *strings* para
  coincidir con `Jason` y simplificar la depuración de archivos.
  """

  use GenServer

  @name __MODULE__

  @trainers_file "trainers.json"
  @pokemon_file "pokemon.json"
  @moves_file "moves.json"
  @tienda_file "tienda.json"
  @battles_log "battles.log"

  # --- API pública: arranque y utilidades ---

  @doc "Inicia el proceso de persistencia (registrado como `#{inspect(@name)}`)."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Directorio absoluto donde viven los JSON (`config :proyecto_pokemon, :data_dir`)."
  def data_dir do
    Application.fetch_env!(:proyecto_pokemon, :data_dir)
  end

  @doc "Hash SHA-256 en Base64 para almacenar contraseñas sin texto plano."
  def hash_clave(clave) when is_binary(clave) do
    :crypto.hash(:sha256, clave) |> Base.encode64()
  end

  @doc "Verifica contraseña contra el hash almacenado."
  def verificar_clave?(clave, hash_almacenado)
      when is_binary(clave) and is_binary(hash_almacenado) do
    hash_clave(clave) == hash_almacenado
  end

  # --- Entrenadores ---

  @doc "Obtiene el mapa del entrenador o `nil` si no existe."
  def obtener_entrenador(usuario), do: GenServer.call(@name, {:obtener_entrenador, usuario})

  @doc """
  Crea o actualiza un entrenador. Si `attrs` incluye `:clave` o `\"clave\"`,
  se sustituye por `\"clave_hash\"` antes de guardar.
  """
  def guardar_entrenador(usuario, attrs) when is_map(attrs) do
    GenServer.call(@name, {:guardar_entrenador, usuario, attrs})
  end

  @doc "Lista todos los entrenadores (mapa usuario -> datos)."
  def listar_entrenadores, do: GenServer.call(@name, :listar_entrenadores)

  # --- Inventario (IDs de instancias) ---

  @doc "IDs de Pokémon-instancia en inventario del usuario."
  def inventario_pokemon(usuario), do: GenServer.call(@name, {:inventario_pokemon, usuario})

  @doc "Añade un ID de instancia al inventario del usuario."
  def agregar_al_inventario(usuario, pokemon_id),
    do: GenServer.call(@name, {:agregar_al_inventario, usuario, pokemon_id})

  @doc "Quita un ID del inventario (p. ej. tras intercambio)."
  def quitar_del_inventario(usuario, pokemon_id),
    do: GenServer.call(@name, {:quitar_del_inventario, usuario, pokemon_id})

  # --- Sobres ---

  @doc "Número de sobres sin abrir."
  def sobres_sin_abrir(usuario), do: GenServer.call(@name, {:sobres, usuario})

  @doc "Incrementa o decrementa sobres (delta entero)."
  def ajustar_sobres(usuario, delta) when is_integer(delta),
    do: GenServer.call(@name, {:ajustar_sobres, usuario, delta})

  # --- Equipos (1–3 Pokémon, nombres únicos por usuario) ---

  @doc "Mapa nombre_equipo -> [ids]."
  def listar_equipos(usuario), do: GenServer.call(@name, {:listar_equipos, usuario})

  @doc "Crea o reemplaza un equipo. Valida 1–3 IDs existentes en inventario y nombre único."
  def guardar_equipo(usuario, nombre_equipo, pokemon_ids),
    do: GenServer.call(@name, {:guardar_equipo, usuario, nombre_equipo, pokemon_ids})

  @doc "Elimina un equipo por nombre."
  def eliminar_equipo(usuario, nombre_equipo),
    do: GenServer.call(@name, {:eliminar_equipo, usuario, nombre_equipo})

  # --- Instancias Pokémon ---

  @doc "Inserta una nueva instancia (sin campo `id`); devuelve el id asignado."
  def crear_instancia_pokemon(mapa_sin_id) when is_map(mapa_sin_id) do
    GenServer.call(@name, {:crear_instancia_pokemon, mapa_sin_id})
  end

  @doc "Obtiene instancia por id (entero o string coercible)."
  def obtener_instancia(id), do: GenServer.call(@name, {:obtener_instancia, id})

  @doc "Actualiza instancia con función `(map -> map)`."
  def actualizar_instancia(id, fun) when is_function(fun, 1),
    do: GenServer.call(@name, {:actualizar_instancia, id, fun})

  @doc "Catálogo de especies (solo lectura): nombre especie -> datos base."
  def catalogo_especies, do: GenServer.call(@name, :catalogo_especies)

  # --- Datos estáticos ---

  @doc "Contenido completo de `moves.json` (movimientos por tipo + globales)."
  def catalogo_movimientos, do: GenServer.call(@name, :catalogo_movimientos)

  @doc "Precios y metadatos de la tienda (`tienda.json`)."
  def catalogo_tienda, do: GenServer.call(@name, :catalogo_tienda)

  # --- Monedas e historial ---

  @doc "Ajusta monedas del entrenador (puede ser negativo si hay saldo)."
  def ajustar_monedas(usuario, delta) when is_integer(delta),
    do: GenServer.call(@name, {:ajustar_monedas, usuario, delta})

  @doc "Añade una entrada al historial del entrenador (lista de términos serializables a JSON)."
  def agregar_historial(usuario, entrada) when is_list(entrada) or is_map(entrada),
    do: GenServer.call(@name, {:agregar_historial, usuario, entrada})

  # --- Log de batallas ---

  @doc "Añade una línea de texto al archivo `battles.log` (fecha ISO8601 la añade el caller o aquí)."
  def append_battle_log(linea) when is_binary(linea) do
    GenServer.cast(@name, {:append_battle_log, linea})
  end

  # --- GenServer ---

  defmodule State do
    @moduledoc false
    defstruct [:trainers, :pokemon_doc, :moves, :tienda]
  end

  @impl true
  def init(_opts) do
    ensure_data_dir!()
    trainers = load_json!(@trainers_file, %{"usuarios" => %{}})
    pokemon_doc = load_json!(@pokemon_file, default_pokemon_doc())
    moves = load_json!(@moves_file, %{"por_tipo" => %{}, "globales" => []})
    tienda = load_json!(@tienda_file, %{})

    state = %State{
      trainers: trainers,
      pokemon_doc: normalize_pokemon_doc(pokemon_doc),
      moves: moves,
      tienda: tienda
    }

    {:ok, state}
  end

  defp default_pokemon_doc do
    %{
      "next_id" => 1,
      "instancias" => %{},
      "especies_catalogo" => %{}
    }
  end

  defp normalize_pokemon_doc(doc) do
    doc
    |> Map.put_new("next_id", 1)
    |> Map.put_new("instancias", %{})
    |> Map.put_new("especies_catalogo", %{})
  end

  @impl true
  def handle_call({:obtener_entrenador, usuario}, _from, state) do
    u = to_string(usuario)
    usuarios = get_in(state.trainers, ["usuarios"]) || %{}
    {:reply, Map.get(usuarios, u), state}
  end

  def handle_call(:listar_entrenadores, _from, state) do
    {:reply, get_in(state.trainers, ["usuarios"]) || %{}, state}
  end

  def handle_call({:guardar_entrenador, usuario, attrs}, _from, state) do
    u = to_string(usuario)
    usuarios = get_in(state.trainers, ["usuarios"]) || %{}
    actual = Map.get(usuarios, u, entrenador_vacio())

    merged =
      attrs
      |> stringify_keys()
      |> maybe_hash_password()
      |> then(&Map.merge(actual, &1))

    nuevos_usuarios = Map.put(usuarios, u, merged)
    trainers = put_in(state.trainers, ["usuarios"], nuevos_usuarios)
    new_state = %{state | trainers: trainers}
    persist_trainers!(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:inventario_pokemon, usuario}, _from, state) do
    case entrenador(state, usuario) do
      nil -> {:reply, {:error, :no_existe}, state}
      t -> {:reply, {:ok, t["inventario_pokemon_ids"] || []}, state}
    end
  end

  def handle_call({:agregar_al_inventario, usuario, pokemon_id}, _from, state) do
    id = to_id(pokemon_id)

    with {:ok, state2} <- ensure_entrenador(state, usuario),
         :ok <- ensure_instancia(state, id) do
      t = entrenador(state2, usuario)
      lista = t["inventario_pokemon_ids"] || []

      if id in lista do
        {:reply, {:error, :ya_en_inventario}, state2}
      else
        t2 = Map.put(t, "inventario_pokemon_ids", lista ++ [id])
        {:reply, :ok, put_entrenador!(state2, usuario, t2)}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:quitar_del_inventario, usuario, pokemon_id}, _from, state) do
    id = to_id(pokemon_id)

    case entrenador(state, usuario) do
      nil ->
        {:reply, {:error, :no_existe}, state}

      t ->
        lista = t["inventario_pokemon_ids"] || []
        t2 = Map.put(t, "inventario_pokemon_ids", List.delete(lista, id))
        {:reply, :ok, put_entrenador!(state, usuario, t2)}
    end
  end

  def handle_call({:sobres, usuario}, _from, state) do
    case entrenador(state, usuario) do
      nil -> {:reply, {:error, :no_existe}, state}
      t -> {:reply, {:ok, t["sobres_sin_abrir"] || 0}, state}
    end
  end

  def handle_call({:ajustar_sobres, usuario, delta}, _from, state) do
    case entrenador(state, usuario) do
      nil ->
        {:reply, {:error, :no_existe}, state}

      t ->
        n = max(0, (t["sobres_sin_abrir"] || 0) + delta)
        t2 = Map.put(t, "sobres_sin_abrir", n)
        {:reply, {:ok, n}, put_entrenador!(state, usuario, t2)}
    end
  end

  def handle_call({:listar_equipos, usuario}, _from, state) do
    case entrenador(state, usuario) do
      nil -> {:reply, {:error, :no_existe}, state}
      t -> {:reply, {:ok, t["equipos"] || %{}}, state}
    end
  end

  def handle_call({:guardar_equipo, usuario, nombre_equipo, pokemon_ids}, _from, state) do
    nombre = to_string(nombre_equipo)
    ids = Enum.map(pokemon_ids, &to_id/1)

    cond do
      nombre == "" ->
        {:reply, {:error, :nombre_invalido}, state}

      length(ids) < 1 or length(ids) > 3 ->
        {:reply, {:error, :tamano_equipo_invalido}, state}

      length(ids) != length(Enum.uniq(ids)) ->
        {:reply, {:error, :pokemon_duplicado_en_equipo}, state}

      true ->
        case entrenador(state, usuario) do
          nil ->
            {:reply, {:error, :no_existe}, state}

          t ->
            equipos = t["equipos"] || %{}
            inventario = MapSet.new(t["inventario_pokemon_ids"] || [])

            if Enum.all?(ids, &(&1 in inventario)) do
              equipos2 = Map.put(equipos, nombre, ids)
              t2 = Map.put(t, "equipos", equipos2)
              {:reply, :ok, put_entrenador!(state, usuario, t2)}
            else
              {:reply, {:error, :pokemon_no_en_inventario}, state}
            end
        end
    end
  end

  def handle_call({:eliminar_equipo, usuario, nombre_equipo}, _from, state) do
    nombre = to_string(nombre_equipo)

    case entrenador(state, usuario) do
      nil ->
        {:reply, {:error, :no_existe}, state}

      t ->
        equipos = t["equipos"] || %{}

        if Map.has_key?(equipos, nombre) do
          t2 = Map.put(t, "equipos", Map.delete(equipos, nombre))
          {:reply, :ok, put_entrenador!(state, usuario, t2)}
        else
          {:reply, {:error, :no_existe_equipo}, state}
        end
    end
  end

  def handle_call({:crear_instancia_pokemon, mapa}, _from, state) do
    doc = state.pokemon_doc
    next = doc["next_id"] || 1
    id = next

    instancia =
      mapa
      |> stringify_keys()
      |> Map.put("id", id)

    instancias = doc["instancias"] || %{}
    instancias2 = Map.put(instancias, to_string(id), instancia)
    doc2 = doc |> Map.put("instancias", instancias2) |> Map.put("next_id", next + 1)
    new_state = %{state | pokemon_doc: doc2}
    persist_pokemon!(new_state)
    {:reply, {:ok, id}, new_state}
  end

  def handle_call({:obtener_instancia, id}, _from, state) do
    key = to_string(to_id(id))
    inst = get_in(state.pokemon_doc, ["instancias", key])
    {:reply, inst, state}
  end

  def handle_call({:actualizar_instancia, id, fun}, _from, state) do
    key = to_string(to_id(id))
    inst = get_in(state.pokemon_doc, ["instancias", key])

    if inst == nil do
      {:reply, {:error, :no_existe}, state}
    else
      inst2 = fun.(inst)
      doc = state.pokemon_doc
      instancias = Map.put(doc["instancias"] || %{}, key, inst2)
      doc2 = Map.put(doc, "instancias", instancias)
      new_state = %{state | pokemon_doc: doc2}
      persist_pokemon!(new_state)
      {:reply, :ok, new_state}
    end
  end

  def handle_call(:catalogo_especies, _from, state) do
    {:reply, state.pokemon_doc["especies_catalogo"] || %{}, state}
  end

  def handle_call(:catalogo_movimientos, _from, state) do
    {:reply, state.moves, state}
  end

  def handle_call(:catalogo_tienda, _from, state) do
    {:reply, state.tienda, state}
  end

  def handle_call({:ajustar_monedas, usuario, delta}, _from, state) do
    case entrenador(state, usuario) do
      nil ->
        {:reply, {:error, :no_existe}, state}

      t ->
        monedas = (t["monedas"] || 0) + delta

        if monedas < 0 do
          {:reply, {:error, :saldo_insuficiente}, state}
        else
          t2 = Map.put(t, "monedas", monedas)
          {:reply, {:ok, monedas}, put_entrenador!(state, usuario, t2)}
        end
    end
  end

  def handle_call({:agregar_historial, usuario, entrada}, _from, state) do
    case entrenador(state, usuario) do
      nil ->
        {:reply, {:error, :no_existe}, state}

      t ->
        hist = t["historial"] || []
        item = %{"fecha" => DateTime.utc_now() |> DateTime.to_iso8601(), "dato" => entrada}
        t2 = Map.put(t, "historial", hist ++ [item])
        {:reply, :ok, put_entrenador!(state, usuario, t2)}
    end
  end

  @impl true
  def handle_cast({:append_battle_log, linea}, state) do
    path = Path.join(data_dir(), @battles_log)
    File.write!(path, linea <> "\n", [:append])
    {:noreply, state}
  end

  # --- Internos ---

  defp entrenador_vacio do
    %{
      "clave_hash" => "",
      "monedas" => 0,
      "historial" => [],
      "inventario_pokemon_ids" => [],
      "sobres_sin_abrir" => 0,
      "equipos" => %{}
    }
  end

  defp entrenador(state, usuario) do
    u = to_string(usuario)
    get_in(state.trainers, ["usuarios", u])
  end

  defp ensure_entrenador(state, usuario) do
    if entrenador(state, usuario), do: {:ok, state}, else: {:error, :no_existe}
  end

  defp ensure_instancia(state, id) do
    key = to_string(id)
    if get_in(state.pokemon_doc, ["instancias", key]),
      do: :ok,
      else: {:error, :pokemon_inexistente}
  end

  defp put_entrenador!(state, usuario, trainer_map) do
    u = to_string(usuario)
    trainers = put_in(state.trainers, ["usuarios", u], trainer_map)
    new_state = %{state | trainers: trainers}
    persist_trainers!(new_state)
    new_state
  end

  defp maybe_hash_password(attrs) do
    cond do
      Map.has_key?(attrs, "clave") ->
        h = hash_clave(attrs["clave"])
        attrs |> Map.delete("clave") |> Map.put("clave_hash", h)

      Map.has_key?(attrs, :clave) ->
        h = hash_clave(to_string(attrs[:clave]))
        attrs |> Map.delete(:clave) |> Map.put("clave_hash", h)

      true ->
        attrs
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys_val(v)}
      {k, v} -> {to_string(k), stringify_keys_val(v)}
    end)
  end

  defp stringify_keys_val(v) when is_map(v), do: stringify_keys(v)
  defp stringify_keys_val(v) when is_list(v), do: Enum.map(v, &stringify_keys_val/1)
  defp stringify_keys_val(v), do: v

  defp to_id(id) when is_integer(id), do: id
  defp to_id(id) when is_binary(id), do: String.to_integer(id)

  defp ensure_data_dir! do
    dir = data_dir()
    :ok = File.mkdir_p(dir)
  end

  defp load_json!(filename, default) do
    path = Path.join(data_dir(), filename)

    if File.exists?(path) do
      path |> File.read!() |> Jason.decode!()
    else
      atomic_write_json!(filename, default)
      default
    end
  end

  defp persist_trainers!(%State{trainers: t}) do
    atomic_write_json!(@trainers_file, t)
  end

  defp persist_pokemon!(%State{pokemon_doc: doc}) do
    atomic_write_json!(@pokemon_file, doc)
  end

  defp atomic_write_json!(filename, term) do
    dir = data_dir()
    path = Path.join(dir, filename)
    tmp = path <> ".tmp"
    bin = Jason.encode!(term, pretty: true)
    :ok = File.write(tmp, bin)
    :ok = File.rename(tmp, path)
  end
end
