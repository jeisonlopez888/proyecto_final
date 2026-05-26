defmodule PokemonBattle.GestorSalas do
  @moduledoc """
  **Punto único de entrada** para salas de batalla e intercambio en el nodo local (o remoto vía RPC).

  Registra IDs de sala (`S-1001`, `I-1001`), crea procesos hijos bajo supervisión y reenvía comandos
  al `Batalla` o `Intercambio` correspondiente. Si defines la variable de entorno `GESTOR_SALAS_NODE`,
  todas las llamadas públicas se delegan a ese nodo BEAM conectado, de modo que varias consolas compartan el mismo gestor.

  Depende de `SupervisorBatallas` para las batallas y de un `DynamicSupervisor` interno para intercambios.
  """

  use GenServer

  alias PokemonBattle.SupervisorBatallas
  alias PokemonBattle.Intercambio
  alias PokemonBattle.Batalla

  defstruct next_batalla_id: 1001,
            next_intercambio_id: 1001,
            batallas: %{}, # room_id => pid
            intercambios: %{}, # room_id => pid
            intercambio_supervisor: nil,
            monitors: %{} # ref => {type, room_id}

  # =========================
  # API pública
  # =========================

  @doc """
  Arranca el `GenServer` registrado como `PokemonBattle.GestorSalas`; debe formar parte del árbol de supervisión.
  """
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Normaliza IDs de sala (`s-1001` → `S-1001`, `i-1001` → `I-1001`).
  """
  def normalizar_id_sala(room_id) when is_binary(room_id) do
    room_id = String.trim(room_id)

    cond do
      String.match?(room_id, ~r/^s-/i) -> "S-" <> String.slice(room_id, 2..-1//1)
      String.match?(room_id, ~r/^i-/i) -> "I-" <> String.slice(room_id, 2..-1//1)
      true -> room_id
    end
  end

  def normalizar_id_sala(room_id), do: room_id |> to_string() |> normalizar_id_sala()

  # Llamada local usada solo por RPC (`:rpc.call/4`); ver `GESTOR_SALAS_NODE` en `@moduledoc`.
  @doc false
  def __local_gs_call__(msg), do: GenServer.call(__MODULE__, msg)

  defp gs_call(:listar_salas) do
    case rpc_target() do
      nil -> listar_salas_en_cluster()
      n when n == node() -> listar_salas_en_cluster()
      n -> rpc_gs_call(n, :listar_salas)
    end
  end

  defp gs_call(msg) do
    case rpc_target() do
      nil ->
        gs_call_local(msg)

      n when n == node() ->
        gs_call_local(msg)

      n ->
        rpc_gs_call(n, msg)
    end
  end

  defp gs_call_local(msg) do
    case GenServer.call(__MODULE__, msg) do
      {:error, :sala_no_existe} = err ->
        case buscar_en_cluster(msg) do
          {:error, :sala_no_existe} -> err
          other -> other
        end

      other ->
        other
    end
  end

  defp listar_salas_en_cluster do
    nodos = [node() | Node.list()]

    salas =
      nodos
      |> Enum.flat_map(fn n ->
        case rpc_gs_call(n, :listar_salas) do
          {:ok, xs} when is_list(xs) -> xs
          _ -> []
        end
      end)
      |> Enum.uniq_by(& &1.room_id)
      |> Enum.sort_by(& &1.room_id)

    {:ok, salas}
  end

  defp buscar_en_cluster(msg) do
    Node.list()
    |> Enum.find_value({:error, :sala_no_existe}, fn n ->
      case rpc_gs_call(n, msg) do
        {:error, :sala_no_existe} -> nil
        {:badrpc, _} -> nil
        result -> {:found, result}
      end
    end)
    |> case do
      {:found, r} -> r
      err -> err
    end
  end

  defp rpc_gs_call(n, msg) do
    if n == node() do
      GenServer.call(__MODULE__, msg)
    else
      case :rpc.call(n, __MODULE__, :__local_gs_call__, [msg]) do
        {:badrpc, reason} -> {:error, {:rpc, reason}}
        other -> other
      end
    end
  end

  defp rpc_target() do
    case System.get_env("GESTOR_SALAS_NODE") do
      nil -> nil
      "" -> nil
      s -> s |> String.trim() |> String.to_atom()
    end
  end

  @doc """
  Lista salas de batalla e intercambio conocidas por este gestor con su estado resumido.
  """
  def listar_salas() do
    gs_call(:listar_salas)
  end

  @doc """
  Crea una sala de batalla; el `usuario` queda como creador/jugador 1. Opciones pueden incluir `caller_pid` para monitorizar la consola.
  """
  def crear_sala(usuario, opts \\ []) do
    gs_call({:crear_sala, usuario, opts})
  end

  @doc """
  Une al `usuario` a la sala `room_id` (normalizado a `S-...`). `caller_pid` opcional para desconexión del cliente.
  """
  def unirse_sala(room_id, usuario, caller_pid \\ nil) do
    room_id = normalizar_id_sala(room_id)
    gs_call({:unirse_sala, room_id, usuario, caller_pid})
  end

  @doc """
  Inicia el combate cuando hay dos jugadores: carga equipos activos y comienza la máquina de turnos.
  """
  def iniciar_batalla(room_id, usuario_iniciador \\ nil) do
    room_id = normalizar_id_sala(room_id)
    gs_call({:iniciar_batalla, room_id, usuario_iniciador})
  end

  @doc """
  Registra la acción de ataque del `usuario` en la sala con el id de movimiento indicado (debe pertenecer al Pokémon activo de ese jugador).
  """
  def ataque(room_id, usuario, movimiento_id) do
    room_id = normalizar_id_sala(room_id)
    gs_call({:ataque, room_id, usuario, movimiento_id})
  end

  @doc """
  Solicita cambiar al Pokémon de instancia `pokemon_id` del equipo del `usuario` en esa batalla.
  """
  def cambiar(room_id, usuario, pokemon_id) do
    room_id = normalizar_id_sala(room_id)
    gs_call({:cambiar, room_id, usuario, pokemon_id})
  end

  @doc """
  El `usuario` se rinde en la batalla de esa sala; el rival gana y se aplican recompensas según la lógica de `Batalla`.
  """
  def rendirse(room_id, usuario) do
    room_id = normalizar_id_sala(room_id)
    gs_call({:rendirse, room_id, usuario})
  end

  @doc """
  Consulta el último orden de actuación por velocidad en la ronda anterior (útil para pruebas o depuración).
  """
  def obtener_ultimo_orden(room_id) do
    room_id = normalizar_id_sala(room_id)
    gs_call({:obtener_ultimo_orden, room_id})
  end

  @doc """
  Devuelve un resumen del estado de la batalla en esa sala (HP, turno, jugadores, etc.).
  """
  def obtener_batalla_estado(room_id) do
    room_id = normalizar_id_sala(room_id)
    gs_call({:obtener_batalla_estado, room_id})
  end

  # =========================
  # Intercambio
  # =========================

  @doc """
  Crea una sala de intercambio; el primer jugador queda registrado esperando al segundo.
  """
  def crear_sala_intercambio(usuario, opts \\ []) do
    gs_call({:crear_sala_intercambio, usuario, opts})
  end

  @doc """
  Une al segundo entrenador a la sala de intercambio `I-...`.
  """
  def unirse_sala_intercambio(room_id, usuario, caller_pid \\ nil) do
    room_id = normalizar_id_sala(room_id)
    gs_call({:unirse_sala_intercambio, room_id, usuario, caller_pid})
  end

  @doc """
  El `usuario` ofrece un Pokémon de su inventario (id de instancia) para el intercambio.
  """
  def ofrecer_pokemon_intercambio(room_id, usuario, pokemon_id) do
    room_id = normalizar_id_sala(room_id)
    gs_call({:ofrecer_pokemon_intercambio, room_id, usuario, pokemon_id})
  end

  @doc """
  Marca confirmación del `usuario`. Cuando ambos confirman, se intercambian inventarios en persistencia (sin mutar `dueño_original`).
  """
  def confirmar_intercambio(room_id, usuario) do
    room_id = normalizar_id_sala(room_id)
    gs_call({:confirmar_intercambio, room_id, usuario})
  end

  @doc """
  Cancela el intercambio desde el lado del `usuario` (o ante desconexión monitorizada).
  """
  def cancelar_intercambio(room_id, usuario) do
    room_id = normalizar_id_sala(room_id)
    gs_call({:cancelar_intercambio, room_id, usuario})
  end

  @doc """
  Devuelve el estado de la sala de intercambio (ofertas, confirmaciones, jugadores).
  """
  def obtener_intercambio_estado(room_id) do
    room_id = normalizar_id_sala(room_id)
    gs_call({:obtener_intercambio_estado, room_id})
  end

  # =========================
  # GenServer callbacks
  # =========================

  @impl true
  def init(_opts) do
    {:ok, intercambio_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, %__MODULE__{intercambio_supervisor: intercambio_supervisor}}
  end

  @impl true
  def handle_call(:listar_salas, _from, state) do
    salas =
      state.batallas
      |> Enum.map(fn {room_id, pid} ->
        estado = Batalla.obtener_estado(pid)

        %{
          room_id: room_id,
          status: estado.status,
          jugadores: estado.jugadores,
          jugador1: estado.jugador1,
          jugador2: estado.jugador2,
          ronda: estado.ronda
        }
      end)
      |> Enum.sort_by(& &1.room_id)

    {:reply, {:ok, salas}, state}
  end

  def handle_call({:crear_sala, usuario, opts}, _from, state) do
    room_id = "S-#{state.next_batalla_id}"
    usuario = to_string(usuario)
    caller_pid = Keyword.get(opts, :caller_pid, nil)
    random_factor = Keyword.get(opts, :random_factor, nil)
    tiempo_turno_ms = Keyword.get(opts, :tiempo_turno_ms, 30_000)
    timeout_espera_ms = Keyword.get(opts, :timeout_espera_ms, 180_000)
    tiempo_batalla_ms = Keyword.get(opts, :tiempo_batalla_ms, 300_000)

    args = %{
      room_id: room_id,
      jugador1: usuario,
      caller_pid: caller_pid,
      random_factor: random_factor,
      tiempo_turno_ms: tiempo_turno_ms,
      timeout_espera_ms: timeout_espera_ms,
      tiempo_batalla_ms: tiempo_batalla_ms
    }

    {:ok, pid} = SupervisorBatallas.start_batalla(args)
    ref = Process.monitor(pid)
    monitors = Map.put(state.monitors, ref, {:batalla, room_id})

    batallas = Map.put(state.batallas, room_id, pid)

    {:reply, {:ok, room_id}, %{state | next_batalla_id: state.next_batalla_id + 1, batallas: batallas, monitors: monitors}}
  end

  def handle_call({:unirse_sala, room_id, usuario, caller_pid}, _from, state) do
    usuario = to_string(usuario)

    case Map.fetch(state.batallas, room_id) do
      {:ok, pid} ->
        {:reply, Batalla.unirse(pid, usuario, caller_pid), state}

      :error ->
        {:reply, {:error, :sala_no_existe}, state}
    end
  end

  def handle_call({:iniciar_batalla, room_id, usuario_iniciador}, _from, state) do
    case Map.fetch(state.batallas, room_id) do
      {:ok, pid} ->
        {:reply, Batalla.iniciar(pid, usuario_iniciador), state}

      :error ->
        {:reply, {:error, :sala_no_existe}, state}
    end
  end

  def handle_call({:ataque, room_id, usuario, movimiento_id}, _from, state) do
    case Map.fetch(state.batallas, room_id) do
      {:ok, pid} -> {:reply, Batalla.ataque(pid, usuario, movimiento_id), state}
      :error -> {:reply, {:error, :sala_no_existe}, state}
    end
  end

  def handle_call({:cambiar, room_id, usuario, pokemon_id}, _from, state) do
    case Map.fetch(state.batallas, room_id) do
      {:ok, pid} -> {:reply, Batalla.cambiar(pid, usuario, pokemon_id), state}
      :error -> {:reply, {:error, :sala_no_existe}, state}
    end
  end

  def handle_call({:rendirse, room_id, usuario}, _from, state) do
    case Map.fetch(state.batallas, room_id) do
      {:ok, pid} -> {:reply, Batalla.rendirse(pid, usuario), state}
      :error -> {:reply, {:error, :sala_no_existe}, state}
    end
  end

  def handle_call({:obtener_ultimo_orden, room_id}, _from, state) do
    case Map.fetch(state.batallas, room_id) do
      {:ok, pid} -> {:reply, Batalla.obtener_ultimo_orden(pid), state}
      :error -> {:reply, {:error, :sala_no_existe}, state}
    end
  end

  def handle_call({:obtener_batalla_estado, room_id}, _from, state) do
    case Map.fetch(state.batallas, room_id) do
      {:ok, pid} -> {:reply, Batalla.obtener_estado(pid), state}
      :error -> {:reply, {:error, :sala_no_existe}, state}
    end
  end

  def handle_call({:crear_sala_intercambio, usuario, opts}, _from, state) do
    room_id = "I-#{state.next_intercambio_id}"
    usuario = to_string(usuario)
    caller_pid = Keyword.get(opts, :caller_pid, nil)
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    args = %{
      room_id: room_id,
      jugador1: usuario,
      caller_pid: caller_pid,
      timeout_ms: timeout_ms
    }

    child_spec = {Intercambio, args}
    {:ok, pid} = DynamicSupervisor.start_child(state.intercambio_supervisor, child_spec)
    ref = Process.monitor(pid)
    monitors = Map.put(state.monitors, ref, {:intercambio, room_id})
    intercambios = Map.put(state.intercambios, room_id, pid)

    {:reply, {:ok, room_id}, %{state | next_intercambio_id: state.next_intercambio_id + 1, intercambios: intercambios, monitors: monitors}}
  end

  def handle_call({:unirse_sala_intercambio, room_id, usuario, caller_pid}, _from, state) do
    usuario = to_string(usuario)

    case Map.fetch(state.intercambios, room_id) do
      {:ok, pid} ->
        {:reply, Intercambio.unirse(pid, usuario, caller_pid), state}

      :error ->
        {:reply, {:error, :sala_no_existe}, state}
    end
  end

  def handle_call({:ofrecer_pokemon_intercambio, room_id, usuario, pokemon_id}, _from, state) do
    case Map.fetch(state.intercambios, room_id) do
      {:ok, pid} -> {:reply, Intercambio.ofrecer_pokemon(pid, usuario, pokemon_id), state}
      :error -> {:reply, {:error, :sala_no_existe}, state}
    end
  end

  def handle_call({:confirmar_intercambio, room_id, usuario}, _from, state) do
    case Map.fetch(state.intercambios, room_id) do
      {:ok, pid} -> {:reply, Intercambio.confirmar_intercambio(pid, usuario), state}
      :error -> {:reply, {:error, :sala_no_existe}, state}
    end
  end

  def handle_call({:cancelar_intercambio, room_id, usuario}, _from, state) do
    case Map.fetch(state.intercambios, room_id) do
      {:ok, pid} -> {:reply, Intercambio.cancelar_intercambio(pid, usuario), state}
      :error -> {:reply, {:error, :sala_no_existe}, state}
    end
  end

  def handle_call({:obtener_intercambio_estado, room_id}, _from, state) do
    case Map.fetch(state.intercambios, room_id) do
      {:ok, pid} -> {:reply, Intercambio.obtener_estado(pid), state}
      :error -> {:reply, {:error, :sala_no_existe}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, ref) do
      {:ok, {type, room_id}} ->
        monitors = Map.delete(state.monitors, ref)

        state =
          case type do
            :batalla -> %{state | batallas: Map.delete(state.batallas, room_id), monitors: monitors}
            :intercambio -> %{state | intercambios: Map.delete(state.intercambios, room_id), monitors: monitors}
          end

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end
end

