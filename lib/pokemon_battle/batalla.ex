defmodule PokemonBattle.Batalla do
  @moduledoc """
  **Sala de batalla** (`GenServer`): una partida entre dos entrenadores con equipos cargados desde persistencia.

  - Turnos **simultáneos**: se acumula una acción por jugador; al completarse ambas, el orden de ejecución
    lo marca la **velocidad** del Pokémon activo de cada uno.
  - Acciones: ataque (id de movimiento), cambio de Pokémon o rendición.
  - Al terminar, actualiza victorias/derrotas, monedas y puede persistir cambios de HP en las instancias.

  La API pública recibe el `pid` del proceso de sala devuelto por el gestor de salas.
  """

  use GenServer

  alias PokemonBattle.MotorCombate
  alias PokemonBattle.Persistencia

  @win_reward 100
  @participacion_perdedor 30

  defstruct room_id: nil,
            jugador1: nil,
            jugador2: nil,
            status: :esperando_jugador2,
            jugadores: [],
            monitors: %{}, # usuario => monitor_ref
            moves_index: %{},
            equipo_por_usuario: %{}, # usuario => equipo
            acciones_pendientes: %{}, # usuario => accion
            ronda: 1,
            ultimo_orden: [],
            random_factor: nil,
            tiempo_turno_ms: 20_000

  # =========================
  # API pública
  # =========================

  @doc """
  Une al segundo jugador a la sala. Opcionalmente monitoriza `caller_pid` para cerrar si cae la sesión de consola.
  """
  def unirse(pid, usuario, caller_pid \\ nil) do
    GenServer.call(pid, {:unirse, usuario, caller_pid})
  end

  @doc """
  Arranca el combate: valida equipos activos de ambos jugadores y entra en el bucle de rondas.
  """
  def iniciar(pid, usuario_iniciador) do
    GenServer.call(pid, {:iniciar, usuario_iniciador})
  end

  @doc """
  Encola ataque del `usuario` con el movimiento indicado (debe ser legal para su Pokémon activo).
  """
  def ataque(pid, usuario, movimiento_id) do
    GenServer.call(pid, {:ataque, usuario, movimiento_id})
  end

  @doc """
  Encola cambio de Pokémon activo del `usuario` hacia la instancia `pokemon_id` de su equipo en batalla.
  """
  def cambiar(pid, usuario, pokemon_id) do
    GenServer.call(pid, {:cambiar, usuario, pokemon_id})
  end

  @doc """
  El `usuario` abandona la batalla; el oponente gana y se aplican recompensas y persistencia.
  """
  def rendirse(pid, usuario) do
    GenServer.call(pid, {:rendirse, usuario})
  end

  @doc """
  Devuelve la lista ordenada de quién actuó primero en la última ronda resuelta (por velocidad). Útil en tests.
  """
  def obtener_ultimo_orden(pid), do: GenServer.call(pid, :obtener_ultimo_orden)

  @doc """
  Devuelve un mapa con el estado actual de la batalla (jugadores, HP, turno, etc.) para depuración o interfaz.
  """
  def obtener_estado(pid), do: GenServer.call(pid, :obtener_estado)

  # =========================
  # GenServer callbacks
  # =========================

  def start_link(%{room_id: _room_id} = args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  def child_spec(%{room_id: room_id} = args) do
    %{
      id: {__MODULE__, room_id},
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary,
      type: :worker
    }
  end

  @impl true
  def init(%{room_id: room_id, jugador1: jugador1} = args) do
    random_factor = Map.get(args, :random_factor, nil)
    caller_pid = Map.get(args, :caller_pid, nil)
    tiempo_turno_ms = Map.get(args, :tiempo_turno_ms, 20_000)

    jugador1 = to_string(jugador1)
    monitors = %{}

    monitors =
      if is_pid(caller_pid) do
        ref = Process.monitor(caller_pid)
        Map.put(monitors, jugador1, ref)
      else
        monitors
      end

    state = %__MODULE__{
      room_id: to_string(room_id),
      jugador1: jugador1,
      jugador2: nil,
      status: :esperando_jugador2,
      jugadores: [jugador1],
      monitors: monitors,
      equipo_por_usuario: %{},
      acciones_pendientes: %{},
      ronda: 1,
      ultimo_orden: [],
      random_factor: random_factor,
      tiempo_turno_ms: tiempo_turno_ms
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:unirse, usuario, caller_pid}, _from, state) do
    usuario = to_string(usuario)

    cond do
      state.status != :esperando_jugador2 ->
        {:reply, {:error, :ya_iniciada}, state}

      usuario in state.jugadores ->
        {:reply, {:error, :mismo_usuario}, state}

      length(state.jugadores) >= 2 ->
        {:reply, {:error, :sala_llena}, state}

      true ->
        monitors =
          if is_pid(caller_pid) do
            ref = Process.monitor(caller_pid)
            Map.put(state.monitors, usuario, ref)
          else
            state.monitors
          end

        state2 = %{
          state
          | jugador2: usuario,
            jugadores: [hd(state.jugadores), usuario],
            monitors: monitors
        }

        {:reply, {:ok, :unido}, state2}
    end
  end

  @impl true
  def handle_call({:iniciar, usuario_iniciador}, _from, state) do
    cond do
      state.status != :esperando_jugador2 ->
        {:reply, {:error, :ya_iniciada}, state}

      length(state.jugadores) != 2 ->
        {:reply, {:error, :faltan_jugadores}, state}

      true ->
        [u1, u2] = state.jugadores

        with {:ok, moves_index} <- cargar_moves_index(),
             {:ok, equipo_u1} <- cargar_equipo_de_usuario(u1),
             {:ok, equipo_u2} <- cargar_equipo_de_usuario(u2) do
          Persistencia.append_battle_log(
            "#{DateTime.utc_now() |> DateTime.to_iso8601()} [#{state.room_id}] Batalla iniciada por #{to_string(usuario_iniciador)}"
          )

          state2 = %{
            state
            | status: :en_progreso,
              moves_index: moves_index,
              equipo_por_usuario: %{
                u1 => equipo_u1,
                u2 => equipo_u2
              },
              acciones_pendientes: %{},
              ronda: 1
          }

          {:reply, {:ok, %{estado: :en_progreso, jugadores: state2.jugadores}}, state2}
        else
          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:ataque, usuario, movimiento_id}, _from, state) do
    usuario = to_string(usuario)
    movimiento_id = to_string(movimiento_id)

    cond do
      state.status != :en_progreso ->
        {:reply, {:error, :no_en_progreso}, state}

      not Map.has_key?(state.equipo_por_usuario, usuario) ->
        {:reply, {:error, :no_jugador}, state}

      Map.has_key?(state.acciones_pendientes, usuario) ->
        {:reply, {:error, :accion_ya_definida}, state}

      true ->
        activo_id = state.equipo_por_usuario[usuario].activo_id
        activo = state.equipo_por_usuario[usuario].pokemon_por_id[activo_id]

        cond do
          not (movimiento_id in (activo.movimientos || [])) ->
            {:reply, {:error, :movimiento_no_disponible}, state}

          not Map.has_key?(state.moves_index, movimiento_id) ->
            {:reply, {:error, :movimiento_inexistente}, state}

          true ->
            state2 = %{
              state
              | acciones_pendientes: Map.put(state.acciones_pendientes, usuario, {:ataque, movimiento_id})
            }

            if map_size(state2.acciones_pendientes) == 2 do
              {reply, nuevo_estado} = resolver_turno(state2)
              {:reply, reply, nuevo_estado}
            else
              {:reply, {:ok, :esperando_oponente}, state2}
            end
        end
    end
  end

  @impl true
  def handle_call({:cambiar, usuario, pokemon_id}, _from, state) do
    usuario = to_string(usuario)
    pokemon_id = normalize_int_id(pokemon_id)

    cond do
      state.status != :en_progreso ->
        {:reply, {:error, :no_en_progreso}, state}

      not Map.has_key?(state.equipo_por_usuario, usuario) ->
        {:reply, {:error, :no_jugador}, state}

      Map.has_key?(state.acciones_pendientes, usuario) ->
        {:reply, {:error, :accion_ya_definida}, state}

      not (pokemon_id in state.equipo_por_usuario[usuario].equipo_ids) ->
        {:reply, {:error, :pokemon_no_en_equipo}, state}

      not pokemon_vivo?(state, usuario, pokemon_id) ->
        {:reply, {:error, :pokemon_no_vivo}, state}

      true ->
        state2 = %{
          state
          | acciones_pendientes: Map.put(state.acciones_pendientes, usuario, {:cambiar, pokemon_id})
        }

        if map_size(state2.acciones_pendientes) == 2 do
          {reply, nuevo_estado} = resolver_turno(state2)
          {:reply, reply, nuevo_estado}
        else
          {:reply, {:ok, :esperando_oponente}, state2}
        end
    end
  end

  @impl true
  def handle_call({:rendirse, usuario}, _from, state) do
    usuario = to_string(usuario)

    cond do
      state.status != :en_progreso ->
        {:reply, {:error, :no_en_progreso}, state}

      not Map.has_key?(state.equipo_por_usuario, usuario) ->
        {:reply, {:error, :no_jugador}, state}

      true ->
        ganador = oponente_de(state, usuario)

        Persistencia.append_battle_log(
          "#{DateTime.utc_now() |> DateTime.to_iso8601()} [#{state.room_id}] #{usuario} se rinde. Ganador: #{ganador}"
        )

        registrar_resultado_batalla(ganador, usuario)

        state2 = %{
          state
          | status: :terminada,
            acciones_pendientes: %{}
        }

        {:reply, {:ok, %{ganador: ganador}}, state2}
    end
  end

  @impl true
  def handle_call(:obtener_ultimo_orden, _from, state) do
    {:reply, state.ultimo_orden, state}
  end

  @impl true
  def handle_call(:obtener_estado, _from, state) do
    {:reply, resumen_estado(state), state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Forfeit por salida del proceso (cuando el cliente está siendo monitoreado).
    # Nota: para esta entrega no mapeamos exactamente el usuario caído.
    if state.status == :en_progreso and length(state.jugadores) == 2 do
      [u1, u2] = state.jugadores
      ganador = u1
      perdedor = u2

      Persistencia.append_battle_log(
        "#{DateTime.utc_now() |> DateTime.to_iso8601()} [#{state.room_id}] Jugador cae. Ganador: #{ganador}"
      )

      registrar_resultado_batalla(ganador, perdedor)

      {:noreply, %{state | status: :terminada, acciones_pendientes: %{}}}
    else
      {:noreply, state}
    end
  end

  # =========================
  # Resolución de turnos (simultáneos)
  # =========================

  # Retorna {reply, nuevo_estado}
  defp resolver_turno(state) do
    [u1, u2] = state.jugadores
    a1 = state.acciones_pendientes[u1]
    a2 = state.acciones_pendientes[u2]

    p_act_1 = pokemon_activo(state, u1)
    p_act_2 = pokemon_activo(state, u2)

    order =
      [u1, u2]
      |> Enum.sort_by(fn u ->
        if u == u1, do: -p_act_1.velocidad, else: -p_act_2.velocidad
      end)
      |> then(fn sorted ->
        if p_act_1.velocidad == p_act_2.velocidad, do: Enum.shuffle(sorted), else: sorted
      end)

    Persistencia.append_battle_log(
      "#{DateTime.utc_now() |> DateTime.to_iso8601()} [#{state.room_id}] Ronda #{state.ronda}. Orden: #{Enum.join(order, ", ")}"
    )

    # 1) Aplicar ataques siguiendo el orden por velocidad.
    {state_danio, ended?, ganador} =
      Enum.reduce_while(order, {state, false, nil}, fn actor, {st, ended, g} ->
        if ended do
          {:halt, {st, ended, g}}
        else
          op = oponente_de(st, actor)

          case st.acciones_pendientes[actor] do
            {:ataque, mov_id} ->
              atacante = pokemon_activo(st, actor)
              defensor = pokemon_activo(st, op)

              if defensor.hp <= 0 do
                {:cont, {st, ended, g}}
              else
                mov = st.moves_index[mov_id]

                t_atk = tipos_pokemon(atacante)
                t_def = tipos_pokemon(defensor)

                daño =
                  MotorCombate.calcular_dano_movimiento(
                    mov,
                    %{"tipos" => t_atk, "tipo" => hd(t_atk), "ataque" => atacante.ataque},
                    %{"tipos" => t_def, "tipo" => hd(t_def), "defensa" => defensor.defensa},
                    random_factor: st.random_factor
                  )

                Persistencia.append_battle_log(
                  "#{DateTime.utc_now() |> DateTime.to_iso8601()} [#{st.room_id}] #{actor} usa #{mov_id} contra #{op}. Daño: #{daño}"
                )

                st2 = aplicar_dano(st, op, st.equipo_por_usuario[op].activo_id, daño)

                if not pokemon_vivos?(st2, op) do
                  registrar_resultado_batalla(actor, op)
                  Persistencia.append_battle_log(
                    "#{DateTime.utc_now() |> DateTime.to_iso8601()} [#{st2.room_id}] Batalla terminada. Ganador: #{actor}"
                  )
                  {:halt, {%{st2 | status: :terminada}, true, actor}}
                else
                  {:cont, {st2, ended, g}}
                end
              end

            _accion ->
              {:cont, {st, ended, g}}
          end
        end
      end)

    # 2) Si no terminó, aplicar cambios de Pokémon para la siguiente ronda.
    state2 =
      if ended? do
        state_danio
      else
        state2 = aplicar_siguiente_activos(state_danio)
        %{state2 | ultimo_orden: order, acciones_pendientes: %{}, ronda: state.ronda + 1}
      end

    reply =
      if ended? do
        {:ok, %{estado: :terminada, ganador: ganador}}
      else
        {:ok,
         %{
           estado: :ronda_resuelta,
           ronda: state.ronda,
           order: order,
           acciones: %{u1 => a1, u2 => a2}
         }}
      end

    {reply, state2}
  end

  defp aplicar_siguiente_activos(state) do
    [u1, u2] = state.jugadores

    state
    |> ajustar_activo_para_usuario(u1, state.acciones_pendientes[u1])
    |> ajustar_activo_para_usuario(u2, state.acciones_pendientes[u2])
  end

  defp ajustar_activo_para_usuario(state, usuario, accion) do
    equipo = state.equipo_por_usuario[usuario]
    alive_ids = Enum.filter(equipo.equipo_ids, fn id -> equipo.pokemon_por_id[id].hp > 0 end)
    if alive_ids == [] do
      state
    else
      switch_target =
        case accion do
          {:cambiar, id} -> id
          _ -> nil
        end

      next_active =
        cond do
          switch_target && switch_target in alive_ids ->
            switch_target

          equipo.pokemon_por_id[equipo.activo_id].hp > 0 ->
            equipo.activo_id

          true ->
            hd(alive_ids)
        end

      equipo2 = %{equipo | activo_id: next_active}
      %{state | equipo_por_usuario: Map.put(state.equipo_por_usuario, usuario, equipo2)}
    end
  end

  defp pokemon_activo(state, usuario) do
    equipo = state.equipo_por_usuario[usuario]
    equipo.pokemon_por_id[equipo.activo_id]
  end

  defp aplicar_dano(state, usuario, pokemon_id, daño) do
    equipo = state.equipo_por_usuario[usuario]
    pokemon = equipo.pokemon_por_id[pokemon_id]
    hp2 = max((pokemon.hp || 0) - daño, 0)
    pokemon2 = %{pokemon | hp: hp2}
    equipo2 = %{equipo | pokemon_por_id: Map.put(equipo.pokemon_por_id, pokemon_id, pokemon2)}
    %{state | equipo_por_usuario: Map.put(state.equipo_por_usuario, usuario, equipo2)}
  end

  defp pokemon_vivo?(state, usuario, pokemon_id) do
    equipo = state.equipo_por_usuario[usuario]
    pokemon = equipo.pokemon_por_id[pokemon_id]
    pokemon && pokemon.hp > 0
  end

  defp pokemon_vivos?(state, usuario) do
    equipo = state.equipo_por_usuario[usuario]
    Enum.any?(equipo.equipo_ids, fn id -> equipo.pokemon_por_id[id].hp > 0 end)
  end

  # =========================
  # Carga de datos
  # =========================

  defp cargar_moves_index() do
    moves = Persistencia.catalogo_movimientos()
    por_tipo = moves["por_tipo"] || %{}
    globales = moves["globales"] || []

    todos =
      por_tipo
      |> Map.values()
      |> List.flatten()
      |> Kernel.++(globales)

    {:ok, Map.new(todos, fn m -> {to_string(m["id"]), m} end)}
  end

  defp cargar_equipo_de_usuario(usuario) do
    trainer = Persistencia.obtener_entrenador(usuario)

    cond do
      trainer == nil ->
        {:error, :no_existe}

      true ->
        equipos = trainer["equipos"] || %{}
        equipo_activo = trainer["equipo_activo"]

        {nombre_equipo, ids} =
          cond do
            is_nil(equipo_activo) or equipo_activo == "" ->
              if map_size(equipos) == 0 do
                {nil, nil}
              else
                # Si no hay `equipo_activo` elegido, tomamos el primero disponible.
                nombre = equipos |> Map.keys() |> Enum.sort() |> hd()
                Persistencia.guardar_entrenador(usuario, %{"equipo_activo" => nombre})
                {nombre, equipos[nombre]}
              end

            true ->
              {equipo_activo, Map.get(equipos, equipo_activo)}
          end

        cond do
          is_nil(nombre_equipo) or is_nil(ids) ->
            {:error, :equipo_no_seleccionado}

          !is_list(ids) or ids == [] ->
            {:error, :equipo_inexistente}

          true ->
            equipo_ids = Enum.map(ids, &normalize_int_id/1)
            construir_equipo(usuario, equipo_ids)
        end
    end
  end

  defp tipos_especie(data) do
    cond do
      is_list(data["tipos"]) ->
        data["tipos"]

      is_binary(data["tipo"]) && String.contains?(data["tipo"], "/") ->
        data["tipo"] |> String.split("/") |> Enum.map(&String.trim/1)

      data["tipo"] ->
        [data["tipo"]]

      true ->
        ["normal"]
    end
  end

  defp tipos_pokemon(p) do
    Map.get(p, :tipos) ||
      (p.tipo |> to_string() |> String.split("/") |> Enum.map(&String.trim/1))
  end

  defp construir_equipo(usuario, equipo_ids) do
    catalogo_especies = Persistencia.catalogo_especies()

    pokemon_por_id =
      Enum.reduce(equipo_ids, %{}, fn pid, acc ->
        inst = Persistencia.obtener_instancia(pid)

        if inst == nil do
          acc
        else
          especie = inst["especie"]
          especie_data = catalogo_especies[especie] || %{}

          tipos = tipos_especie(especie_data)
          tipo_label = Enum.join(tipos, "/")

          rareza = inst["rareza"] || "comun"

          ataque = inst["ataque"] || 0
          defensa = inst["defensa"] || 0
          velocidad = inst["velocidad"] || 0

          hp_max = 100

          pokemon = %{
            id: pid,
            especie: especie,
            tipo: tipo_label,
            tipos: tipos,
            ataque: ataque,
            defensa: defensa,
            velocidad: velocidad,
            movimientos: inst["movimientos"] || [],
            rareza: rareza,
            hp: hp_max,
            hp_max: hp_max
          }

          Map.put(acc, pid, pokemon)
        end
      end)

    if map_size(pokemon_por_id) == 0 do
      {:error, :pokemon_no_encontrados}
    else
      activo_id = hd(equipo_ids)
      equipo = %{usuario: to_string(usuario), equipo_ids: equipo_ids, pokemon_por_id: pokemon_por_id, activo_id: activo_id}
      {:ok, equipo}
    end
  end

  # =========================
  # Utilidades
  # =========================

  defp normalize_int_id(id) when is_integer(id), do: id
  defp normalize_int_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> String.to_integer(id)
    end
  end

  defp oponente_de(state, usuario) do
    [a, b] = state.jugadores
    if to_string(a) == to_string(usuario), do: to_string(b), else: to_string(a)
  end

  defp registrar_resultado_batalla(ganador, perdedor) do
    ganador = to_string(ganador)
    perdedor = to_string(perdedor)

    # Monedas (ganador +100, perdedor +30 participación; ambas suman a monedas_acumuladas)
    Persistencia.ajustar_monedas(ganador, @win_reward)
    Persistencia.ajustar_monedas(perdedor, @participacion_perdedor)

    # Contadores para clasificación
    g = Persistencia.obtener_entrenador(ganador) || %{}
    p = Persistencia.obtener_entrenador(perdedor) || %{}

    victorias_g = (g["victorias"] || 0) + 1
    derrotas_g = g["derrotas"] || 0

    victorias_p = p["victorias"] || 0
    derrotas_p = (p["derrotas"] || 0) + 1

    Persistencia.guardar_entrenador(ganador, %{
      "victorias" => victorias_g,
      "derrotas" => derrotas_g
    })

    Persistencia.guardar_entrenador(perdedor, %{
      "victorias" => victorias_p,
      "derrotas" => derrotas_p
    })
  end

  defp resumen_estado(state) do
    %{
      room_id: state.room_id,
      status: state.status,
      jugadores: state.jugadores,
      ronda: state.ronda,
      ultimo_orden: state.ultimo_orden,
      acciones_pendientes: state.acciones_pendientes
    }
  end
end

