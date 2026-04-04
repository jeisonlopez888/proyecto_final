defmodule PokemonBattle.SupervisorBatallas do
  @moduledoc """
  `DynamicSupervisor` para administrar salas de batalla en paralelo.
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Inicia una nueva sala de batalla con `PokemonBattle.Batalla`.
  """
  def start_batalla(%{room_id: _room_id, jugador1: _jugador1} = args) do
    child_spec = {PokemonBattle.Batalla, args}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Devuelve todos los pids activos de batallas (para debug/tests).
  """
  def listar_batallas() do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
    |> Enum.filter(&is_pid/1)
  end
end

