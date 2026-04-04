defmodule PokemonBattle.Intercambio do
  @moduledoc """
  **Sala de intercambio** (`GenServer`): dos entrenadores acuerdan intercambiar una instancia cada uno.

  Flujo típico: crear sala → unirse el otro → cada uno **ofrece** un Pokémon de su inventario → ambos **confirman**.
  Si el tiempo global expira, alguien cancela o cae el proceso cliente monitorizado, la sala se cancela sin mover datos.
  Al completarse, se actualizan inventarios en `Persistencia`; el campo `dueño_original` de cada instancia **no** se altera.
  """

  use GenServer

  alias PokemonBattle.Persistencia

  @default_timeout_ms 30_000

  defstruct room_id: nil,
            jugador1: nil,
            jugador2: nil,
            status: :esperando_jugador2,
            monitors: %{}, # usuario => ref
            offers: %{}, # usuario => pokemon_id
            confirms: %{}, # usuario => boolean
            timeout_ms: @default_timeout_ms

  # =========================
  # API pública
  # =========================

  @doc "Une al `usuario` a la sala (segundo jugador). Opcional `caller_pid` para monitorizar la sesión."
  def unirse(pid, usuario, caller_pid \\ nil), do: GenServer.call(pid, {:unirse, usuario, caller_pid})

  @doc "Registra la oferta del `usuario`: id de instancia de Pokémon que entrega."
  def ofrecer_pokemon(pid, usuario, pokemon_id), do: GenServer.call(pid, {:ofrecer_pokemon, usuario, pokemon_id})

  @doc "Confirma el intercambio por parte del `usuario`. Con dos confirmaciones y ofertas válidas se ejecuta el swap."
  def confirmar_intercambio(pid, usuario), do: GenServer.call(pid, {:confirmar_intercambio, usuario})

  @doc "Cancela el intercambio desde el `usuario`."
  def cancelar_intercambio(pid, usuario), do: GenServer.call(pid, {:cancelar_intercambio, usuario})

  @doc "Estado actual de la sala (jugadores, ofertas, confirmaciones, fase)."
  def obtener_estado(pid), do: GenServer.call(pid, :obtener_estado)

  # =========================
  # GenServer
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
    jugador1 = to_string(jugador1)
    timeout_ms = Map.get(args, :timeout_ms, @default_timeout_ms)
    caller_pid = Map.get(args, :caller_pid, nil)

    monitors =
      if is_pid(caller_pid) do
        ref = Process.monitor(caller_pid)
        Map.put(%{}, jugador1, ref)
      else
        %{}
      end

    state = %__MODULE__{
      room_id: to_string(room_id),
      jugador1: jugador1,
      jugador2: nil,
      status: :esperando_jugador2,
      monitors: monitors,
      offers: %{jugador1 => nil},
      confirms: %{jugador1 => false},
      timeout_ms: timeout_ms
    }

    _timer_ref = Process.send_after(self(), :timeout_intercambio, timeout_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:unirse, usuario, caller_pid}, _from, state) do
    usuario = to_string(usuario)

    cond do
      state.jugador2 != nil ->
        {:reply, {:error, :sala_llena}, state}

      usuario == state.jugador1 ->
        {:reply, {:error, :mismo_usuario}, state}

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
            status: :esperando_confirmaciones,
            offers: Map.merge(state.offers, %{usuario => nil}),
            confirms: Map.merge(state.confirms, %{usuario => false}),
            monitors: monitors
        }

        {:reply, {:ok, :unido}, state2}
    end
  end

  @impl true
  def handle_call({:ofrecer_pokemon, usuario, pokemon_id}, _from, state) do
    usuario = to_string(usuario)
    pokemon_id = normalize_int_id(pokemon_id)

    cond do
      state.status == :cancelada or state.status == :completada ->
        {:reply, {:error, :intercambio_finalizado}, state}

      not (usuario == state.jugador1 or usuario == state.jugador2) ->
        {:reply, {:error, :no_jugador}, state}

      true ->
      with {:ok, ids} <- Persistencia.inventario_pokemon(usuario),
           true <- pokemon_id in ids,
           inst = Persistencia.obtener_instancia(pokemon_id),
           true <- inst != nil do
          state2 = %{state | offers: Map.put(state.offers, usuario, pokemon_id)}
          # Si ambos ya confirmaron y ahora completamos la oferta, ejecutamos.
          if state2.jugador2 != nil and
               state2.confirms[state2.jugador1] == true and
               state2.confirms[state2.jugador2] == true and
               not is_nil(state2.offers[state2.jugador1]) and
               not is_nil(state2.offers[state2.jugador2]) do
            ejecutar_intercambio(state2)
          else
            {:reply, {:ok, %{ofrecido: pokemon_id}}, state2}
          end
        else
          _ ->
            {:reply, {:error, :pokemon_no_valido}, state}
        end
    end
  end

  @impl true
  def handle_call({:confirmar_intercambio, usuario}, _from, state) do
    usuario = to_string(usuario)

    cond do
      state.status == :cancelada or state.status == :completada ->
        {:reply, {:error, :intercambio_finalizado}, state}

      not (usuario == state.jugador1 or usuario == state.jugador2) ->
        {:reply, {:error, :no_jugador}, state}

      state.jugador2 == nil ->
        {:reply, {:error, :faltan_jugadores}, state}

      true ->
        state2 = %{state | confirms: Map.put(state.confirms, usuario, true)}

        if state2.confirms[state.jugador1] && state2.confirms[state.jugador2] do
          # Verificamos ofertas completas
          oferta1 = state2.offers[state.jugador1]
          oferta2 = state2.offers[state.jugador2]

          if is_nil(oferta1) or is_nil(oferta2) do
            {:reply, {:ok, :esperando_ofertas}, state2}
          else
            ejecutar_intercambio(state2)
          end
        else
          {:reply, {:ok, :esperando_confirmacion}, state2}
        end
    end
  end

  @impl true
  def handle_call({:cancelar_intercambio, _usuario}, _from, state) do
    ejecutar_cancelacion(state)
  end

  @impl true
  def handle_call(:obtener_estado, _from, state) do
    {:reply, resumen_estado(state), state}
  end

  @impl true
  def handle_info(:timeout_intercambio, state) do
    ejecutar_cancelacion(%{state | status: :cancelada})
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # Si un proceso monitoreado cae, cancelamos.
    if Enum.any?(state.monitors, fn {_u, r} -> r == ref end) do
      ejecutar_cancelacion(%{state | status: :cancelada})
    else
      {:noreply, state}
    end
  end

  # =========================
  # Ejecución
  # =========================

  defp ejecutar_intercambio(state) do
    oferta1 = state.offers[state.jugador1]
    oferta2 = state.offers[state.jugador2]

    # Validación final (en caso de condiciones de carrera)
    with {:ok, ids1} <- Persistencia.inventario_pokemon(state.jugador1),
         {:ok, ids2} <- Persistencia.inventario_pokemon(state.jugador2),
         true <- oferta1 in ids1,
         true <- oferta2 in ids2 do
      :ok = Persistencia.quitar_del_inventario(state.jugador1, oferta1)
      :ok = Persistencia.quitar_del_inventario(state.jugador2, oferta2)

      :ok = Persistencia.agregar_al_inventario(state.jugador1, oferta2)
      :ok = Persistencia.agregar_al_inventario(state.jugador2, oferta1)

      Persistencia.append_battle_log(
        "#{DateTime.utc_now() |> DateTime.to_iso8601()} [#{state.room_id}] Intercambio completo: #{state.jugador1}(#{oferta1}) <-> #{state.jugador2}(#{oferta2})"
      )

      state2 = %{state | status: :completada}
      {:stop, :normal, {:ok, %{intercambiado: true, a: oferta1, b: oferta2}}, state2}
    else
      _ -> {:reply, {:error, :ofertas_invalidas}, state}
    end
  end

  defp ejecutar_cancelacion(state) do
    # No hay cambios de inventario hasta que se confirme ambos, así que cancelar solo detiene.
    Persistencia.append_battle_log(
      "#{DateTime.utc_now() |> DateTime.to_iso8601()} [#{state.room_id}] Intercambio cancelado"
    )

    {:stop, :normal, {:ok, %{cancelado: true}}, %{state | status: :cancelada}}
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

  defp resumen_estado(state) do
    %{
      room_id: state.room_id,
      status: state.status,
      jugador1: state.jugador1,
      jugador2: state.jugador2,
      offers: state.offers,
      confirms: state.confirms
    }
  end
end

