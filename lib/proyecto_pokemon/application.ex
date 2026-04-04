defmodule ProyectoPokemon.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

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
