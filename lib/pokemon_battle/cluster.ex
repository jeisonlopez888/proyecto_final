defmodule PokemonBattle.Cluster do
  @moduledoc """
  Soporte de cluster para ejecutar batallas en otros nodos BEAM.

  - usa `Node.connect/1`
  - permite delegar creación de salas de batalla a un nodo remoto vía `:rpc.call/4`
  """

  @doc """
  Intenta conectar al/los nodos dados en `nodos`.

  `nodos` puede ser una lista de átomos o strings con nombre de nodo BEAM.
  """
  def conectar(nodos) when is_list(nodos) do
    Enum.map(nodos, fn n ->
      nodo = normalizar_nodo(n)
      case nodo do
        nil -> {:error, :nodo_invalido}
        _ -> {:ok, Node.connect(nodo)}
      end
    end)
  end

  @doc """
  Lee env `CLUSTER_NODES` (separado por coma) y conecta.
  """
  def conectar_desde_env() do
    case System.get_env("CLUSTER_NODES") do
      nil -> {:ok, []}
      "" -> {:ok, []}
      s ->
        nodos = s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
        conectar(nodos)
    end
  end

  @doc """
  Elige un nodo para hospedar la batalla.

  - Si `BATTLE_NODE` está definido, intenta usarlo (si está conectado).
  - En caso contrario, usa `Node.self/0`.
  """
  def pick_node() do
    case System.get_env("BATTLE_NODE") do
      nil ->
        Node.self()

      "" ->
        Node.self()

      nodo_str ->
        nodo = normalizar_nodo(nodo_str)
        if nodo && nodo in Node.list() or nodo == Node.self(), do: nodo, else: Node.self()
    end
  end

  @doc """
  Crea una sala de batalla en `nodo_remoto`.

  Requiere que `:proyecto_pokemon` y sus supervisores estén iniciados en el nodo remoto.
  """
  def crear_sala_batalla_en_nodo(nodo_remoto, usuario, opts \\ []) do
    nodo_remoto = normalizar_nodo(nodo_remoto)
    if is_nil(nodo_remoto) do
      {:error, :nodo_invalido}
    else
      :rpc.call(nodo_remoto, PokemonBattle.GestorSalas, :crear_sala, [usuario, opts])
    end
  end

  defp normalizar_nodo(n) when is_atom(n), do: n
  defp normalizar_nodo(nil), do: nil
  defp normalizar_nodo(n) do
    s = n |> to_string() |> String.trim()
    if s == "", do: nil, else: String.to_atom(s)
  rescue
    _ -> nil
  end
end

