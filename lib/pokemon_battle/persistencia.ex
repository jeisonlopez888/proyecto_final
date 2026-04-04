defmodule PokemonBattle.Persistencia do
  @moduledoc """
  Capa de **persistencia** del juego: todo lo que debe sobrevivir entre ejecuciones
  pasa por este módulo.

  ## Para qué sirve

  - Centralizar lectura/escritura de archivos JSON en **un solo proceso** (`GenServer`)
    para que dos batallas o dos comandos no escriban a la vez y corrompan datos.
  - Mantener **entrenadores**, **inventario**, **equipos**, **sobres**, **instancias de Pokémon**
    y catálogos estáticos (especies, movimientos, tienda).

  ## Qué archivos toca

  - `trainers.json` — usuarios, monedas, inventario, equipos, cola de sobres.
  - `pokemon.json` — catálogo de especies e **instancias** (cada Pokémon concreto).
  - `moves.json` — movimientos disponibles en combate.
  - `tienda.json` — precios y probabilidades de sobres.
  - `battles.log` — registro textual de eventos (append).

  Cada cambio relevante **guarda en disco** (estrategia segura con archivo temporal + renombre).

  Las claves en memoria y JSON son **strings** para alinearlas con `Jason` y facilitar inspección manual.
  """

  use GenServer

  @name __MODULE__

  @trainers_file "trainers.json"
  @pokemon_file "pokemon.json"
  @moves_file "moves.json"
  @tienda_file "tienda.json"
  @battles_log "battles.log"

  # --- API pública: arranque y utilidades ---

  @doc """
  Arranca el `GenServer` de persistencia con nombre registrado `#{inspect(@name)}`.
  Debe estar en el árbol de supervisión de la aplicación para que el juego pueda leer/escribir datos.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Devuelve el directorio de datos (ruta absoluta) donde están `trainers.json`, `pokemon.json`, etc.
  Se configura con `config :proyecto_pokemon, :data_dir`.
  """
  def data_dir do
    Application.fetch_env!(:proyecto_pokemon, :data_dir)
  end

  @doc """
  Calcula el hash SHA-256 de la contraseña y lo codifica en Base64.
  Sirve para guardar solo el hash en `trainers.json`, nunca la clave en claro.
  """
  def hash_clave(clave) when is_binary(clave) do
    :crypto.hash(:sha256, clave) |> Base.encode64()
  end

  @doc """
  Comprueba si la contraseña en texto plano coincide con el `clave_hash` guardado (mismo algoritmo que `hash_clave/1`).
  """
  def verificar_clave?(clave, hash_almacenado)
      when is_binary(clave) and is_binary(hash_almacenado) do
    hash_clave(clave) == hash_almacenado
  end

  # --- Entrenadores ---

  @doc """
  Lee el registro completo del entrenador (mapa con monedas, inventario, equipos, etc.) o `nil` si el usuario no existe.
  """
  def obtener_entrenador(usuario), do: GenServer.call(@name, {:obtener_entrenador, usuario})

  @doc """
  Crea o actualiza un entrenador. Si `attrs` incluye `:clave` o `\"clave\"`,
  se sustituye por `\"clave_hash\"` antes de guardar.
  """
  def guardar_entrenador(usuario, attrs) when is_map(attrs) do
    GenServer.call(@name, {:guardar_entrenador, usuario, attrs})
  end

  @doc """
  Devuelve un mapa `usuario => datos` con todos los entrenadores cargados en memoria (útil para ranking y administración).
  """
  def listar_entrenadores, do: GenServer.call(@name, :listar_entrenadores)

  # --- Inventario (IDs de instancias) ---

  @doc """
  Lista los IDs numéricos de instancias de Pokémon que posee el entrenador. Formato `{:ok, [id, ...]}`.
  """
  def inventario_pokemon(usuario), do: GenServer.call(@name, {:inventario_pokemon, usuario})

  @doc """
  Registra que el entrenador posee una nueva instancia (tras sobre, compra o registro). Persiste `trainers.json`.
  """
  def agregar_al_inventario(usuario, pokemon_id),
    do: GenServer.call(@name, {:agregar_al_inventario, usuario, pokemon_id})

  @doc """
  Elimina un ID del inventario del usuario (por ejemplo al ceder el Pokémon en un intercambio). No borra la instancia en `pokemon.json`.
  """
  def quitar_del_inventario(usuario, pokemon_id),
    do: GenServer.call(@name, {:quitar_del_inventario, usuario, pokemon_id})

  # --- Sobres ---

  @doc """
  Devuelve el contador numérico de “sobres sin abrir” (campo legado; la apertura real usa la cola `cola_sobres`).
  """
  def sobres_sin_abrir(usuario), do: GenServer.call(@name, {:sobres, usuario})

  @doc """
  Suma o resta al contador `sobres_sin_abrir` del entrenador (entero `delta`).
  """
  def ajustar_sobres(usuario, delta) when is_integer(delta),
    do: GenServer.call(@name, {:ajustar_sobres, usuario, delta})

  @doc """
  Encola un sobre comprado al final (FIFO). `clave_sobre` es la clave en `tienda.json` (p. ej. `sobre_basico`).
  """
  def push_sobre_cola(usuario, clave_sobre),
    do: GenServer.call(@name, {:push_sobre_cola, usuario, clave_sobre})

  @doc """
  Extrae el siguiente sobre de la cola para abrirlo. Devuelve `{:ok, clave}` o `{:error, :cola_vacia}`.
  """
  def pop_sobre_cola(usuario), do: GenServer.call(@name, {:pop_sobre_cola, usuario})

  # --- Equipos (1–3 Pokémon, nombres únicos por usuario) ---

  @doc """
  Lista equipos guardados: `{:ok, %{\"nombre_equipo\" => [id1, id2, ...]}}` con hasta 3 Pokémon por equipo.
  """
  def listar_equipos(usuario), do: GenServer.call(@name, {:listar_equipos, usuario})

  @doc """
  Crea un equipo nuevo o sustituye uno existente con el mismo nombre. Exige 1–3 IDs que estén en el inventario y nombre único por usuario.
  """
  def guardar_equipo(usuario, nombre_equipo, pokemon_ids),
    do: GenServer.call(@name, {:guardar_equipo, usuario, nombre_equipo, pokemon_ids})

  @doc """
  Borra un equipo por nombre para ese usuario.
  """
  def eliminar_equipo(usuario, nombre_equipo),
    do: GenServer.call(@name, {:eliminar_equipo, usuario, nombre_equipo})

  @doc """
  Quita un Pokémon (por id de instancia) de un equipo guardado.
  No permite dejar el equipo vacío. Devuelve `:ok` o `{:error, razón}`.
  """
  def equipo_quitar_pokemon(usuario, nombre_equipo, pokemon_id),
    do: GenServer.call(@name, {:equipo_quitar_pokemon, usuario, nombre_equipo, pokemon_id})

  @doc """
  Añade un Pokémon del inventario a un equipo existente (máximo 3 por equipo).
  Devuelve `:ok` o `{:error, razón}` si está lleno, duplicado o no en inventario.
  """
  def equipo_agregar_pokemon(usuario, nombre_equipo, pokemon_id),
    do: GenServer.call(@name, {:equipo_agregar_pokemon, usuario, nombre_equipo, pokemon_id})

  # --- Instancias Pokémon ---

  @doc """
  Crea un Pokémon concreto (instancia) en `pokemon.json`: asigna `id` autoincremental y devuelve `{:ok, id}`.
  El mapa no debe incluir `id` todavía.
  """
  def crear_instancia_pokemon(mapa_sin_id) when is_map(mapa_sin_id) do
    GenServer.call(@name, {:crear_instancia_pokemon, mapa_sin_id})
  end

  @doc """
  Obtiene el mapa de una instancia por su `id` (acepta entero o cadena numérica) o `nil` si no existe.
  """
  def obtener_instancia(id), do: GenServer.call(@name, {:obtener_instancia, id})

  @doc """
  Aplica una función `fn instancia -> instancia_actualizada` y persiste el resultado (p. ej. tras recibir daño en batalla).
  """
  def actualizar_instancia(id, fun) when is_function(fun, 1),
    do: GenServer.call(@name, {:actualizar_instancia, id, fun})

  @doc """
  Catálogo estático de especies: nombre de especie → tipos, stats base, etc. (solo lectura desde `pokemon.json`).
  """
  def catalogo_especies, do: GenServer.call(@name, :catalogo_especies)

  # --- Datos estáticos ---

  @doc """
  Devuelve la estructura completa de `moves.json`: movimientos agrupados por tipo y lista global (para combate y generación al abrir sobres).
  """
  def catalogo_movimientos, do: GenServer.call(@name, :catalogo_movimientos)

  @doc """
  Devuelve el catálogo de la tienda: precios de sobres y probabilidades de rareza por tipo de sobre (`tienda.json`).
  """
  def catalogo_tienda, do: GenServer.call(@name, :catalogo_tienda)

  # --- Monedas e historial ---

  @doc """
  Suma o resta monedas al saldo del entrenador.
  Si `delta` es positivo, también incrementa `monedas_acumuladas` (historial para ranking).
  Falla con `{:error, :saldo_insuficiente}` si el saldo quedaría negativo.
  """
  def ajustar_monedas(usuario, delta) when is_integer(delta),
    do: GenServer.call(@name, {:ajustar_monedas, usuario, delta})

  @doc """
  Añade un elemento al historial interno del entrenador (mapa o lista serializable a JSON).
  Sirve para auditoría o extensiones futuras.
  """
  def agregar_historial(usuario, entrada) when is_list(entrada) or is_map(entrada),
    do: GenServer.call(@name, {:agregar_historial, usuario, entrada})

  # --- Log de batallas ---

  @doc """
  Añade **una línea** al final de `battles.log` (operación asíncrona `cast`, no bloquea).
  Útil para registrar inicio/fin de batalla e hitos sin pasar por el mapa de entrenador.
  """
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

  def handle_call({:push_sobre_cola, usuario, clave}, _from, state) do
    clave = to_string(clave)

    case entrenador(state, usuario) do
      nil ->
        {:reply, {:error, :no_existe}, state}

      t ->
        cola = ensure_cola_sobres(t)
        cola2 = cola ++ [clave]
        t2 = t |> Map.put("cola_sobres", cola2) |> Map.put("sobres_sin_abrir", length(cola2))
        {:reply, :ok, put_entrenador!(state, usuario, t2)}
    end
  end

  def handle_call({:pop_sobre_cola, usuario}, _from, state) do
    case entrenador(state, usuario) do
      nil ->
        {:reply, {:error, :no_existe}, state}

      t ->
        cola = ensure_cola_sobres(t)

        case cola do
          [] ->
            {:reply, {:error, :no_hay_sobres}, state}

          [h | rest] ->
            t2 = t |> Map.put("cola_sobres", rest) |> Map.put("sobres_sin_abrir", length(rest))
            {:reply, {:ok, h}, put_entrenador!(state, usuario, t2)}
        end
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

            if Map.has_key?(equipos, nombre) do
              {:reply, {:error, :nombre_equipo_ocupado}, state}
            else
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
  end

  def handle_call({:equipo_quitar_pokemon, usuario, nombre_equipo, pokemon_id}, _from, state) do
    nombre = to_string(nombre_equipo)
    id = to_id(pokemon_id)

    case entrenador(state, usuario) do
      nil ->
        {:reply, {:error, :no_existe}, state}

      t ->
        equipos = t["equipos"] || %{}

        case Map.get(equipos, nombre) do
          nil ->
            {:reply, {:error, :equipo_inexistente}, state}

          ids when length(ids) <= 1 ->
            {:reply, {:error, :equipo_minimo_un_pokemon}, state}

          ids ->
            ids2 = List.delete(ids, id)

            if length(ids2) == length(ids) do
              {:reply, {:error, :pokemon_no_en_equipo}, state}
            else
              equipos2 = Map.put(equipos, nombre, ids2)
              t2 = Map.put(t, "equipos", equipos2)
              {:reply, :ok, put_entrenador!(state, usuario, t2)}
            end
        end
    end
  end

  def handle_call({:equipo_agregar_pokemon, usuario, nombre_equipo, pokemon_id}, _from, state) do
    nombre = to_string(nombre_equipo)
    id = to_id(pokemon_id)

    case entrenador(state, usuario) do
      nil ->
        {:reply, {:error, :no_existe}, state}

      t ->
        equipos = t["equipos"] || %{}
        inventario = MapSet.new(t["inventario_pokemon_ids"] || [])

        case Map.get(equipos, nombre) do
          nil ->
            {:reply, {:error, :equipo_inexistente}, state}

          ids ->
            cond do
              length(ids) >= 3 ->
                {:reply, {:error, :equipo_lleno}, state}

              id in ids ->
                {:reply, {:error, :pokemon_duplicado_en_equipo}, state}

              id not in inventario ->
                {:reply, {:error, :pokemon_no_en_inventario}, state}

              true ->
                equipos2 = Map.put(equipos, nombre, ids ++ [id])
                t2 = Map.put(t, "equipos", equipos2)
                {:reply, :ok, put_entrenador!(state, usuario, t2)}
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
          acum = t["monedas_acumuladas"] || 0
          acum2 = if delta > 0, do: acum + delta, else: acum
          t2 = t |> Map.put("monedas", monedas) |> Map.put("monedas_acumuladas", acum2)
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

  defp ensure_cola_sobres(t) do
    cola = t["cola_sobres"]
    n = t["sobres_sin_abrir"] || 0

    cond do
      is_list(cola) && cola != [] ->
        cola

      n > 0 ->
        List.duplicate("sobre_basico", n)

      true ->
        []
    end
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
