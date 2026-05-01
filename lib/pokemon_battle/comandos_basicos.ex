defmodule PokemonBattle.ComandosBasicos do
  @moduledoc """
  Capa simple para usar el proyecto como principiante.

  Este modulo envuelve `PokemonBattle.Servidor.comando/1` con funciones
  faciles de leer y recordar. Internamente sigue usando la arquitectura OTP
  recomendada del proyecto (GenServer + Supervisores + persistencia en archivos).
  """

  alias PokemonBattle.Servidor

  @doc "Inicia sesion (o registra automaticamente) con usuario y clave."
  def iniciar(usuario, clave) do
    Servidor.comando("iniciar #{usuario} #{clave}")
  end

  @doc "Cierra la sesion actual."
  def salir do
    Servidor.comando("salir")
  end

  @doc "Muestra el perfil del usuario logueado."
  def perfil do
    Servidor.comando("perfil")
  end

  @doc "Muestra el inventario del usuario logueado."
  def inventario do
    Servidor.comando("inventario")
  end

  @doc "Muestra la tienda de sobres."
  def tienda do
    Servidor.comando("tienda")
  end

  @doc "Compra un sobre por tipo: basico o avanzado."
  def comprar_sobre(tipo) do
    Servidor.comando("comprar_sobre #{tipo}")
  end

  @doc "Abre el siguiente sobre pendiente (cola FIFO)."
  def abrir_sobre do
    Servidor.comando("abrir_sobre ultimo")
  end

  @doc "Crea un equipo con ids en formato lista (ej: [1,2,3])."
  def crear_equipo(nombre, ids) when is_list(ids) do
    ids_txt =
      ids
      |> Enum.map(&to_string/1)
      |> Enum.join(",")

    Servidor.comando("crear_equipo #{nombre} #{ids_txt}")
  end

  @doc "Selecciona equipo activo para batalla."
  def usar_equipo(nombre) do
    Servidor.comando("usar_equipo #{nombre}")
  end

  @doc "Crea una sala de batalla."
  def crear_sala do
    Servidor.comando("crear_sala")
  end

  @doc "Se une a una sala por id (ej: S-1001)."
  def unirse_sala(room_id) do
    Servidor.comando("unirse_sala #{room_id}")
  end

  @doc "Inicia una batalla en la sala indicada."
  def iniciar_batalla(room_id) do
    Servidor.comando("iniciar_batalla #{room_id}")
  end

  @doc "Ataca usando el id de movimiento del pokemon activo."
  def ataque(movimiento_id) do
    Servidor.comando("ataque #{movimiento_id}")
  end

  @doc "Cambia al pokemon por id de instancia."
  def cambiar(pokemon_id) do
    Servidor.comando("cambiar #{pokemon_id}")
  end

  @doc "Muestra lista de comandos recomendados para practica."
  def ayuda do
    comandos =
      comandos_principiante()
      |> formatear_lista_recursiva()

    {:ok, "Comandos basicos:\n" <> comandos}
  end

  @doc """
  Lista simple en formato de strings.

  Se deja publica para que puedas practicar colecciones y Enum.
  """
  def comandos_principiante do
    [
      "iniciar usuario clave",
      "perfil",
      "inventario",
      "tienda",
      "comprar_sobre basico",
      "abrir_sobre ultimo",
      "crear_equipo nombre 1,2,3",
      "usar_equipo nombre",
      "crear_sala",
      "unirse_sala S-1001",
      "iniciar_batalla S-1001",
      "ataque rayo"
    ]
  end

  # Ejemplo claro de recursividad basica en Elixir.
  defp formatear_lista_recursiva([]), do: ""
  defp formatear_lista_recursiva([x]), do: "- " <> x
  defp formatear_lista_recursiva([x | resto]), do: "- " <> x <> "\n" <> formatear_lista_recursiva(resto)
end
