defmodule PokemonBattle.Batalla do
  @moduledoc """
  **Sala de batalla** (`GenServer`): una partida entre dos entrenadores con equipos cargados desde persistencia.

  - Turnos **simultáneos**: se acumula una acción por jugador; al completarse ambas, el orden de ejecución
    lo marca la **velocidad** del Pokémon activo de cada uno.
  - Acciones: ataque (id de movimiento), cambio de Pokémon o rendición.
  - Al terminar, actualiza victorias/derrotas, monedas y puede persistir cambios de HP en las instancias.
  - Timeouts: 3 min sin oponente, 30 s por turno, 5 min máximo de batalla (gana quien menos daño recibió).

  La API pública recibe el `pid` del proceso de sala devuelto por el gestor de salas.
  """

  use GenServer

  alias PokemonBattle.MotorCombate
  alias PokemonBattle.Persistencia
  alias PokemonBattle.FormatoConsola

  @win_reward 100
  @participacion_perdedor 30
  @default_tiempo_turno_ms 30_000
  @default_tiempo_batalla_ms 300_000
  @default_timeout_espera_ms 180_000

  defstruct room_id: nil,
            jugador1: nil,
            jugador2: nil,
            status: :esperando_jugador2,
            jugadores: [],
            monitors: %{},
            sesiones: %{},
            moves_index: %{},
            equipo_por_usuario: %{},
            acciones_pendientes: %{},
            daño_recibido: %{},
            ronda: 1,
            ultimo_orden: [],
            random_factor: nil,
            tiempo_turno_ms: @default_tiempo_turno_ms,
            tiempo_batalla_ms: @default_tiempo_batalla_ms,
            timeout_espera_ms: @default_timeout_espera_ms,
            timer_espera_ref: nil,
            timer_batalla_ref: nil,
            timer_turno_ref: nil,
            ronda_turno_timer: nil

  # =========================
  # API pública
  # =========================

  def unirse(pid, usuario, caller_pid \\ nil) do
    GenServer.call(pid, {:unirse, usuario, caller_pid})
  end

  def iniciar(pid, usuario_iniciador) do
    GenServer.call(pid, {:iniciar, usuario_iniciador})
  end

  def ataque(pid, usuario, movimiento_id) do
    GenServer.call(pid, {:ataque, usuario, movimiento_id})
  end

  def cambiar(pid, usuario, pokemon_id) do
    GenServer.call(pid, {:cambiar, usuario, pokemon_id})
  end

  def rendirse(pid, usuario) do
    GenServer.call(pid, {:rendirse, usuario})
  end

  def obtener_ultimo_orden(pid), do: GenServer.call(pid, :obtener_ultimo_orden)

  def obtener_estado(pid), do: GenServer.call(pid, :obtener_estado)

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
    tiempo_turno_ms = Map.get(args, :tiempo_turno_ms, @default_tiempo_turno_ms)
    tiempo_batalla_ms = Map.get(args, :tiempo_batalla_ms, @default_tiempo_batalla_ms)
    timeout_espera_ms = Map.get(args, :timeout_espera_ms, @default_timeout_espera_ms)

    jugador1 = to_string(jugador1)
    {monitors, sesiones} = registrar_sesion(%{}, %{}, jugador1, caller_pid)

    timer_espera_ref = Process.send_after(self(), :timeout_espera_oponente, timeout_espera_ms)

    state = %__MODULE__{
      room_id: to_string(room_id),
      jugador1: jugador1,
      jugador2: nil,
      status: :esperando_jugador2,
      jugadores: [jugador1],
      monitors: monitors,
      sesiones: sesiones,
      equipo_por_usuario: %{},
      acciones_pendientes: %{},
      daño_recibido: %{jugador1 => 0},
      ronda: 1,
      ultimo_orden: [],
      random_factor: random_factor,
      tiempo_turno_ms: tiempo_turno_ms,
      tiempo_batalla_ms: tiempo_batalla_ms,
      timeout_espera_ms: timeout_espera_ms,
      timer_espera_ref: timer_espera_ref
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:unirse, usuario, caller_pid}, _from, state) do
    usuario = to_string(usuario)

    cond do
      state.status not in [:esperando_jugador2, :lista_para_iniciar] ->
        {:reply, {:error, :ya_iniciada}, state}

      usuario in state.jugadores ->
        {:reply, {:error, :mismo_usuario}, state}

      length(state.jugadores) >= 2 ->
        {:reply, {:error, :sala_llena}, state}

      true ->
        {monitors, sesiones} = registrar_sesion(state.monitors, state.sesiones, usuario, caller_pid)

        state2 =
          cancelar_timer_espera(%{
            state
            | jugador2: usuario,
              jugadores: [hd(state.jugadores), usuario],
              monitors: monitors,
              sesiones: sesiones,
              daño_recibido: Map.put(state.daño_recibido, usuario, 0),
              status: :lista_para_iniciar
          })

        notificar(
          state2,
          "¡#{usuario} se unió a la sala #{state2.room_id}! La batalla va a comenzar…"
        )

        {_reply, state3} = iniciar_combate_interno(state2, usuario)

        {:reply, {:ok, :unido}, state3}
    end
  end

  @impl true
  def handle_call({:iniciar, usuario_iniciador}, _from, state) do
    cond do
      state.status == :en_progreso ->
        {:reply, {:ok, %{estado: :en_progreso, resumen: resumen_estado(state)}}, state}

      state.status == :terminada ->
        {:reply, {:error, :batalla_terminada}, state}

      length(state.jugadores) != 2 ->
        {:reply, {:error, :faltan_jugadores}, state}

      true ->
        {reply, state2} = iniciar_combate_interno(state, usuario_iniciador)
        {:reply, reply, state2}
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
            state2 =
              cancelar_timer_turno(%{
                state
                | acciones_pendientes:
                    Map.put(state.acciones_pendientes, usuario, {:ataque, movimiento_id})
              })

            {:reply, reply, state3} = respuesta_tras_accion(state2)
            {:reply, reply, state3}
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
        state2 =
          cancelar_timer_turno(%{
            state
            | acciones_pendientes:
                Map.put(state.acciones_pendientes, usuario, {:cambiar, pokemon_id})
          })

        {:reply, reply, state3} = respuesta_tras_accion(state2)
        {:reply, reply, state3}
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
        state2 = finalizar_batalla(state, ganador, usuario, :rendicion)
        {:reply, {:ok, %{ganador: ganador, estado: resumen_estado(state2)}}, state2}
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
  def handle_info(:timeout_espera_oponente, state) do
    if state.status == :esperando_jugador2 do
      notificar(
        state,
        "La sala #{state.room_id} se cerró: nadie se unió en 3 minutos (falta de contrincante)."
      )

      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:timeout_batalla, state) do
    if state.status == :en_progreso do
      [u1, u2] = state.jugadores
      d1 = Map.get(state.daño_recibido, u1, 0)
      d2 = Map.get(state.daño_recibido, u2, 0)

      {ganador, perdedor} =
        cond do
          d1 < d2 -> {u1, u2}
          d2 < d1 -> {u2, u1}
          true -> if :rand.uniform() == 1, do: {u1, u2}, else: {u2, u1}
        end

      notificar(
        state,
        "Tiempo de batalla agotado (5 min). Daño recibido — #{u1}: #{d1}, #{u2}: #{d2}. " <>
          "Gana #{ganador} (menor daño sufrido)."
      )

      state2 = finalizar_batalla(state, ganador, perdedor, :tiempo)
      {:noreply, state2}
    else
      {:noreply, state}
    end
  end

  def handle_info({:timeout_turno, ronda}, state) do
    if state.status == :en_progreso and state.ronda == ronda do
      state2 = aplicar_timeout_turno(state)

      case state2.status do
        :terminada ->
          {:noreply, state2}

        :en_progreso ->
          if map_size(state2.acciones_pendientes) == 2 do
            {_, state3} = resolver_turno(state2)
            {:noreply, state3}
          else
            {:noreply, programar_timer_turno(state2)}
          end
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    usuario_caido =
      Enum.find_value(state.monitors, fn {u, r} -> if r == ref, do: u end)

    state2 =
      if usuario_caido do
        %{state | monitors: Map.delete(state.monitors, usuario_caido), sesiones: Map.delete(state.sesiones, usuario_caido)}
      else
        state
      end

    if state2.status == :en_progreso and length(state2.jugadores) == 2 and usuario_caido do
      ganador = oponente_de(state2, usuario_caido)
      state3 = finalizar_batalla(state2, ganador, usuario_caido, :desconexion)
      {:noreply, state3}
    else
      {:noreply, state2}
    end
  end

  # =========================
  # Inicio de combate
  # =========================

  defp iniciar_combate_interno(state, usuario_iniciador) do
    [u1, u2] = state.jugadores

    with {:ok, moves_index} <- cargar_moves_index(),
         {:ok, equipo_u1} <- cargar_equipo_de_usuario(u1),
         {:ok, equipo_u2} <- cargar_equipo_de_usuario(u2) do
      Persistencia.append_battle_log(
        "#{DateTime.utc_now() |> DateTime.to_iso8601()} [#{state.room_id}] Batalla iniciada por #{to_string(usuario_iniciador)}"
      )

      state2 =
        cancelar_timer_espera(%{
          state
          | status: :en_progreso,
            moves_index: moves_index,
            equipo_por_usuario: %{u1 => equipo_u1, u2 => equipo_u2},
            acciones_pendientes: %{},
            daño_recibido: %{u1 => 0, u2 => 0},
            ronda: 1
        })

      timer_batalla_ref = Process.send_after(self(), :timeout_batalla, state2.tiempo_batalla_ms)

      msg_equipos =
        "=== BATALLA INICIADA en #{state2.room_id} ===\n\n" <>
          FormatoConsola.formatear_equipo(u1, equipo_u1, moves_index) <>
          "\n\n" <>
          FormatoConsola.formatear_equipo(u2, equipo_u2, moves_index) <>
          "\n\nTienes #{div(state2.tiempo_turno_ms, 1000)} s por turno. La batalla dura como máximo 5 min."

      notificar(state2, msg_equipos)
      notificar_turno(state2)

      state3 = %{state2 | timer_batalla_ref: timer_batalla_ref} |> programar_timer_turno()

      {{:ok, %{estado: :en_progreso, jugadores: state3.jugadores, resumen: resumen_estado(state3)}}, state3}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp respuesta_tras_accion(state) do
    if map_size(state.acciones_pendientes) == 2 do
      {reply, nuevo_estado} = resolver_turno(state)
      {:reply, reply, nuevo_estado}
    else
      {:reply, {:ok, :esperando_oponente}, programar_timer_turno(state)}
    end
  end

  # =========================
  # Resolución de turnos
  # =========================

  defp resolver_turno(state) do
    [u1, u2] = state.jugadores
    a1 = Map.get(state.acciones_pendientes, u1, {:pasar, nil})
    a2 = Map.get(state.acciones_pendientes, u2, {:pasar, nil})

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

    {state_danio, ended?, ganador, eventos_danio} =
      Enum.reduce_while(order, {state, false, nil, []}, fn actor, {st, ended, g, evs} ->
        if ended do
          {:halt, {st, ended, g, evs}}
        else
          op = oponente_de(st, actor)

          case Map.get(st.acciones_pendientes, actor, {:pasar, nil}) do
            {:ataque, mov_id} ->
              atacante = pokemon_activo(st, actor)
              defensor = pokemon_activo(st, op)

              if defensor.hp <= 0 do
                {:cont, {st, ended, g, evs}}
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

                hp_antes = defensor.hp

                Persistencia.append_battle_log(
                  "#{DateTime.utc_now() |> DateTime.to_iso8601()} [#{st.room_id}] #{actor} usa #{mov_id} contra #{op}. Daño: #{daño}"
                )

                st2 = aplicar_dano(st, op, st.equipo_por_usuario[op].activo_id, daño)
                defensor2 = pokemon_activo(st2, op)

                ev =
                  "#{actor} → #{op}: #{mov["nombre"] || mov_id} causó #{daño} de daño (#{hp_antes} → #{defensor2.hp} HP)"

                evs2 = [ev | evs]

                if not pokemon_vivos?(st2, op) do
                  {:halt, {st2, true, actor, evs2}}
                else
                  {:cont, {st2, ended, g, evs2}}
                end
              end

            {:pasar, _} ->
              evs2 = ["#{actor} perdió su turno (sin acción a tiempo)" | evs]
              {:cont, {st, ended, g, evs2}}

            _accion ->
              {:cont, {st, ended, g, evs}}
          end
        end
      end)

    state2 =
      if ended? do
        finalizar_batalla(state_danio, ganador, oponente_de(state_danio, ganador), :knockout)
      else
        state2 = aplicar_siguiente_activos(state_danio)
        %{state2 | ultimo_orden: order, acciones_pendientes: %{}, ronda: state.ronda + 1}
      end

    msg_ronda =
      eventos_danio
      |> Enum.reverse()
      |> Enum.join("\n")

    unless ended? do
      notificar(
        state2,
        "— Ronda #{state.ronda} —\n#{msg_ronda}\n\n" <> texto_ataques_disponibles(state2)
      )

      notificar_turno(state2)
    end

    reply =
      if ended? do
        {:ok, %{estado: :terminada, ganador: ganador, eventos: eventos_danio}}
      else
        {:ok,
         %{
           estado: :ronda_resuelta,
           ronda: state.ronda,
           order: order,
           acciones: %{u1 => a1, u2 => a2},
           eventos: eventos_danio
         }}
      end

    {reply, programar_timer_turno(state2)}
  end

  defp texto_ataques_disponibles(state) do
    state.jugadores
    |> Enum.map(fn u ->
      activo = pokemon_activo(state, u)
      movs = FormatoConsola.formatear_movimientos(activo.movimientos || [], state.moves_index)
      danio = Map.get(state.daño_recibido, u, 0)
      "  #{u} [#{activo.especie} HP #{activo.hp}/#{activo.hp_max}, daño recibido total: #{danio}]\n     Ataques: #{movs}"
    end)
    |> Enum.join("\n")
  end

  defp aplicar_siguiente_activos(state) do
    [u1, u2] = state.jugadores

    state
    |> ajustar_activo_para_usuario(u1, Map.get(state.acciones_pendientes, u1))
    |> ajustar_activo_para_usuario(u2, Map.get(state.acciones_pendientes, u2))
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
          switch_target && switch_target in alive_ids -> switch_target
          equipo.pokemon_por_id[equipo.activo_id].hp > 0 -> equipo.activo_id
          true -> hd(alive_ids)
        end

      equipo2 = %{equipo | activo_id: next_active}
      %{state | equipo_por_usuario: Map.put(state.equipo_por_usuario, usuario, equipo2)}
    end
  end

  defp aplicar_timeout_turno(state) do
    [u1, u2] = state.jugadores
    faltantes = Enum.filter([u1, u2], fn u -> not Map.has_key?(state.acciones_pendientes, u) end)

    state2 =
      Enum.reduce(faltantes, state, fn u, st ->
        notificar(st, "¡#{u} no actuó en #{div(st.tiempo_turno_ms, 1000)} s y pierde su turno!")
        %{st | acciones_pendientes: Map.put(st.acciones_pendientes, u, {:pasar, nil})}
      end)

    state2
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

    daño_map = Map.update(state.daño_recibido, usuario, daño, &(&1 + daño))

    %{
      state
      | equipo_por_usuario: Map.put(state.equipo_por_usuario, usuario, equipo2),
        daño_recibido: daño_map
    }
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

  defp finalizar_batalla(state, ganador, perdedor, motivo) do
    state2 = cancelar_timer_turno(cancelar_timer_batalla(state))

    Persistencia.append_battle_log(
      "#{DateTime.utc_now() |> DateTime.to_iso8601()} [#{state.room_id}] Fin (#{motivo}). Ganador: #{ganador}"
    )

    registrar_resultado_batalla(ganador, perdedor)

    g = Persistencia.obtener_entrenador(ganador) || %{}
    p = Persistencia.obtener_entrenador(perdedor) || %{}

    notificar(
      state2,
      "=== FIN DE BATALLA ===\nGanador: #{ganador} | Perdedor: #{perdedor}\n" <>
        "Récord #{ganador}: #{g["victorias"] || 0}V / #{g["derrotas"] || 0}D\n" <>
        "Récord #{perdedor}: #{p["victorias"] || 0}V / #{p["derrotas"] || 0}D"
    )

    %{state2 | status: :terminada, acciones_pendientes: %{}}
  end

  # =========================
  # Timers y notificaciones
  # =========================

  defp programar_timer_turno(state) do
    state = cancelar_timer_turno(state)
    ref = Process.send_after(self(), {:timeout_turno, state.ronda}, state.tiempo_turno_ms)
    %{state | timer_turno_ref: ref, ronda_turno_timer: state.ronda}
  end

  defp cancelar_timer_turno(%{timer_turno_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | timer_turno_ref: nil}
  end

  defp cancelar_timer_turno(state), do: state

  defp cancelar_timer_espera(%{timer_espera_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | timer_espera_ref: nil}
  end

  defp cancelar_timer_espera(state), do: state

  defp cancelar_timer_batalla(%{timer_batalla_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | timer_batalla_ref: nil}
  end

  defp cancelar_timer_batalla(state), do: state

  defp notificar(state, mensaje) do
    Enum.each(state.sesiones, fn {_u, pid} ->
      if is_pid(pid) and Process.alive?(pid), do: send(pid, {:batalla_evento, state.room_id, mensaje})
    end)

    :ok
  end

  defp notificar_turno(state) do
    seg = div(state.tiempo_turno_ms, 1000)
    notificar(state, "Turno #{state.ronda}: elige ataque o cambio (#{seg} s).")
  end

  defp registrar_sesion(monitors, sesiones, usuario, caller_pid) do
    monitors =
      if is_pid(caller_pid) do
        ref = Process.monitor(caller_pid)
        Map.put(monitors, usuario, ref)
      else
        monitors
      end

    sesiones =
      if is_pid(caller_pid) do
        Map.put(sesiones, usuario, caller_pid)
      else
        sesiones
      end

    {monitors, sesiones}
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
      is_list(data["tipos"]) -> data["tipos"]
      is_binary(data["tipo"]) && String.contains?(data["tipo"], "/") -> data["tipo"] |> String.split("/") |> Enum.map(&String.trim/1)
      data["tipo"] -> [data["tipo"]]
      true -> ["normal"]
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

    Persistencia.ajustar_monedas(ganador, @win_reward)
    Persistencia.ajustar_monedas(perdedor, @participacion_perdedor)

    g = Persistencia.obtener_entrenador(ganador) || %{}
    p = Persistencia.obtener_entrenador(perdedor) || %{}

    victorias_g = (g["victorias"] || 0) + 1
    derrotas_g = g["derrotas"] || 0
    victorias_p = p["victorias"] || 0
    derrotas_p = (p["derrotas"] || 0) + 1

    Persistencia.guardar_entrenador(ganador, %{"victorias" => victorias_g, "derrotas" => derrotas_g})
    Persistencia.guardar_entrenador(perdedor, %{"victorias" => victorias_p, "derrotas" => derrotas_p})
  end

  defp resumen_estado(state) do
    %{
      room_id: state.room_id,
      status: state.status,
      jugadores: state.jugadores,
      jugador1: state.jugador1,
      jugador2: state.jugador2,
      ronda: state.ronda,
      ultimo_orden: state.ultimo_orden,
      acciones_pendientes: state.acciones_pendientes,
      equipo_por_usuario: state.equipo_por_usuario,
      daño_recibido: state.daño_recibido,
      moves_index: state.moves_index
    }
  end
end
