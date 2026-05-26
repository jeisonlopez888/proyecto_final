defmodule PokemonBattle.NodoEntrenador do
  @moduledoc """
  Al iniciar sesión, activa el nodo BEAM del entrenador (`usuario@127.0.0.1` por defecto),
  registra el nodo en disco y conecta con otros entrenadores conocidos.

  Permite usar `iex.bat -S mix` en cada terminal sin `--sname` manual: el nombre
  del nodo se fija al hacer login.
  """

  alias PokemonBattle.Persistencia

  @registry_filename "cluster_nodes.json"

  @doc """
  Configura distribución al iniciar sesión. Devuelve texto informativo para la consola.
  """
  def al_iniciar_sesion(usuario) when is_binary(usuario) do
    usuario = String.trim(usuario)

    with {:ok, slug} <- slug_entrenador(usuario),
         :ok <- asegurar_nodo(slug),
         :ok <- asegurar_cookie(),
         :ok <- registrar(slug),
         {:ok, conectados} <- conectar_otros_entrenadores(slug) do
      nodo = nodo_atom(slug)
      msg_base = "Nodo de red: #{inspect(nodo)} (listo para batalla entre terminales)."

      case conectados do
        [] -> {:ok, msg_base}
        xs -> {:ok, msg_base <> " Conectado a: #{Enum.join(xs, ", ")}"}
      end
    else
      {:error, :usuario_invalido} ->
        {:ok, "Sesión local (nombre de usuario no válido para nodo de red)."}

      {:error, {:nodo_otro_entrenador, actual, slug}} ->
        {:ok,
         "Sesión iniciada. Este IEx ya es #{inspect(actual)}; para jugar como #{slug} abre otra terminal."}

      {:error, reason} ->
        {:ok, "Sesión iniciada. Aviso de red: #{inspect(reason)}"}
    end
  end

  def al_iniciar_sesion(usuario), do: al_iniciar_sesion(to_string(usuario))

  @doc """
  Átomo del nodo BEAM para un usuario (`"ana"` → `:"ana@127.0.0.1"` con la config por defecto).
  """
  def nodo_atom(slug) when is_binary(slug) do
    String.to_atom("#{slug}@#{host()}")
  end

  @doc false
  def slug_entrenador(usuario) do
    slug =
      usuario
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]/, "_")
      |> String.trim("_")

    if slug == "" or String.match?(slug, ~r/^[0-9]/),
      do: {:error, :usuario_invalido},
      else: {:ok, slug}
  end

  @doc false
  def asegurar_nodo(slug) do
    objetivo = nodo_atom(slug)
    actual = Node.self()

    cond do
      actual == objetivo ->
        :ok

      distribuido_otro_nombre?(actual, objetivo) ->
        {:error, {:nodo_otro_entrenador, actual, slug}}

      true ->
        case Node.start(objetivo) do
          {:error, {:already_started, _}} ->
            if Node.self() == objetivo, do: :ok, else: {:error, {:nodo_otro_entrenador, Node.self(), slug}}

          {:error, reason} ->
            {:error, reason}

          _ ->
            if Node.self() == objetivo, do: :ok, else: {:error, :no_se_pudo_nombrar_nodo}
        end
    end
  end

  @doc false
  def registrar(slug) do
    path = registry_path()
    :ok = File.mkdir_p(Persistencia.data_dir())

    mapa =
      case File.read(path) do
        {:ok, bin} -> Jason.decode!(bin)
        {:error, :enoent} -> %{}
      end

    entrada = %{
      "node" => Atom.to_string(nodo_atom(slug)),
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    mapa = Map.put(mapa, slug, entrada)
    File.write!(path, Jason.encode!(mapa, pretty: true))
    :ok
  end

  @doc false
  def conectar_otros_entrenadores(slug_actual) do
    slug_actual = to_string(slug_actual)

    nodos =
      registry_path()
      |> leer_registro()
      |> Map.drop([slug_actual])
      |> Map.values()
      |> Enum.map(& &1["node"])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&normalizar_nodo_registro/1)
      |> Enum.uniq()

    conectados =
      Enum.reduce(nodos, [], fn nodo, acc ->
        if nodo == Node.self() do
          acc
        else
          case conectar(nodo) do
            true -> [Atom.to_string(nodo) | acc]
            _ -> acc
          end
        end
      end)

    {:ok, Enum.reverse(conectados)}
  end

  defp conectar(nodo) do
    case Node.connect(nodo) do
      true -> true
      false -> :net_adm.ping(nodo) == :pong
      :ignored -> nodo == Node.self()
    end
  end

  defp leer_registro(path) do
    case File.read(path) do
      {:ok, bin} -> Jason.decode!(bin)
      {:error, :enoent} -> %{}
    end
  rescue
    _ -> %{}
  end

  defp registry_path, do: Path.join(Persistencia.data_dir(), @registry_filename)

  defp asegurar_cookie do
    if Node.alive?() do
      Node.set_cookie(String.to_atom(cookie()))
    end

    :ok
  end

  defp cookie do
    System.get_env("ERL_COOKIE") ||
      Application.get_env(:proyecto_pokemon, :cluster_cookie, "proyecto_pokemon")
  end

  defp host do
    Application.get_env(:proyecto_pokemon, :cluster_host, "127.0.0.1")
  end

  defp normalizar_nodo_registro(node_str) when is_binary(node_str) do
    node_str
    |> String.replace("@localhost", "@#{host()}")
    |> String.to_atom()
  end

  defp distribuido_otro_nombre?(actual, objetivo) do
    Node.alive?() and actual != :nonode@nohost and actual != objetivo
  end
end
