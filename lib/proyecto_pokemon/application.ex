defmodule ProyectoPokemon.Application do
  @moduledoc """
  Aplicación OTP del proyecto: arranca la persistencia, el supervisor de batallas,
  el gestor de salas, el servidor de consola y opcionalmente conecta nodos (`Cluster.conectar_desde_env/0`).
  """

  use Application

  @doc """
  Punto de arranque: inicia el supervisor principal con hijos en orden `Persistencia` → `SupervisorBatallas` → `GestorSalas` → `Servidor`.
  Tras un arranque correcto intenta `Node.connect` según la variable de entorno `CLUSTER_NODES`.
  """
  @impl true
  def start(_type, _args) do
    children = [
      {PokemonBattle.Persistencia, []},
      {PokemonBattle.SupervisorBatallas, []},
      {PokemonBattle.GestorSalas, []},
      {PokemonBattle.Servidor, []}
    ]

    opts = [strategy: :one_for_one, name: ProyectoPokemon.Supervisor]

    with {:ok, sup} <- Supervisor.start_link(children, opts) do
      _ = PokemonBattle.Cluster.conectar_desde_env()
      {:ok, sup}
    end
  end
end
