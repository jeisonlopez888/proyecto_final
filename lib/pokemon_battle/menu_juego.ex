defmodule PokemonBattle.MenuJuego do
  @moduledoc """
  Menú interactivo por consola (`IO.gets` / `IO.puts`).

  Guía al jugador con números y textos claros. Por debajo solo llama a
  `PokemonBattle.Servidor.comando/1`, sin duplicar reglas de negocio.
  """

  alias PokemonBattle.Servidor

  @doc """
  Arranca el menú principal. Asegura que la aplicación OTP esté iniciada
  (útil si llamas esto desde `iex` sin `iex -S mix`).
  """
  def iniciar do
    _ = Application.ensure_all_started(:proyecto_pokemon)
    IO.puts("")
    IO.puts("============================================================")
    IO.puts("   BATALLAS POKÉMON — Menú interactivo")
    IO.puts("   Escribe el número de la opción y pulsa Enter.")
    IO.puts("============================================================")
    menu_entrada()
  end

  # --- Pantalla inicial (cuenta) ---

  defp menu_entrada do
    IO.puts("")
    IO.puts("--- CUENTA ---")
    IO.puts("  1) Iniciar sesión (ya tengo usuario y contraseña)")
    IO.puts("  2) Crear entrenador / primera vez (elige usuario y contraseña nuevos)")
    IO.puts("     (Si el usuario no existe, se crea; si existe, entra con su clave.)")
    IO.puts("  0) Salir del programa")
    IO.puts("")

    case leer_opcion() do
      "0" ->
        IO.puts("¡Hasta luego!")
        :ok

      "1" ->
        flujo_entrar("Iniciar sesión")

      "2" ->
        flujo_entrar("Crear entrenador / registrar")

      _ ->
        IO.puts("Opción no válida. Prueba de nuevo.")
        menu_entrada()
    end
  end

  defp flujo_entrar(titulo) do
    IO.puts("")
    IO.puts("--- #{titulo} ---")
    usuario = leer_texto("Nombre de entrenador (usuario): ")
    clave = leer_texto("Contraseña: ")

    if usuario == "" or clave == "" do
      IO.puts("Usuario y contraseña no pueden estar vacíos.")
      menu_entrada()
    else
      case Servidor.comando("iniciar #{usuario} #{clave}") do
        {:ok, msg} ->
          IO.puts("")
          IO.puts(msg)
          menu_jugador()

        {:error, msg} ->
          IO.puts("")
          IO.puts(msg)
          menu_entrada()
      end
    end
  end

  # --- Menú principal (logueado) ---

  defp menu_jugador do
    IO.puts("")
    IO.puts("==========================================================")
    IO.puts("  MENU PRINCIPAL - Escribe un numero y pulsa Enter")
    IO.puts("==========================================================")
    IO.puts("")
    IO.puts("  CUENTA Y POKÉMON")
    IO.puts("  1) Mi perfil y récord (monedas, victorias, derrotas, equipo activo…)")
    IO.puts("  2) Ver mis Pokémon (inventario: stats y movimientos para batalla)")
    IO.puts("")
    IO.puts("  TIENDA")
    IO.puts("  3) Tienda y sobres (ver precios, comprar, abrir paquetes)")
    IO.puts("")
    IO.puts("  EQUIPOS (antes de pelear)")
    IO.puts("  4) Gestionar equipos (crear, listar, activar equipo de hasta 3 Pokémon)")
    IO.puts("")
    IO.puts("  BATALLA")
    IO.puts("  5) Batalla online (crear sala, ver salas activas, unirse, combatir)")
    IO.puts("")
    IO.puts("  INTERCAMBIO Y RANKING")
    IO.puts("  6) Intercambiar Pokémon con otro entrenador (sala I-…)")
    IO.puts("  7) Clasificación global (ranking de todos los jugadores)")
    IO.puts("")
    IO.puts("  SESIÓN")
    IO.puts("  8) Cerrar sesión (volver a iniciar sesión / crear entrenador)")
    IO.puts("  0) Salir del programa por completo")
    IO.puts("")

    case leer_opcion() do
      "0" ->
        IO.puts("¡Hasta luego!")
        :ok

      "1" ->
        ejecutar_y_mostrar("perfil")
        pausa_continuar()
        menu_jugador()

      "2" ->
        ejecutar_y_mostrar("inventario")
        pausa_continuar()
        menu_jugador()

      "3" ->
        menu_tienda_sobres()
        pausa_continuar()
        menu_jugador()

      "4" ->
        menu_equipos()
        pausa_continuar()
        menu_jugador()

      "5" ->
        menu_batalla()
        pausa_continuar()
        menu_jugador()

      "6" ->
        menu_intercambio()
        pausa_continuar()
        menu_jugador()

      "7" ->
        ejecutar_y_mostrar("clasificacion")
        pausa_continuar()
        menu_jugador()

      "8" ->
        ejecutar_y_mostrar("salir")
        menu_entrada()

      _ ->
        IO.puts("Opción no válida.")
        menu_jugador()
    end
  end

  defp pausa_continuar do
    IO.puts("")
    IO.puts("----------------------------------------")
    IO.write("Pulsa Enter para volver al menu principal... ")
    _ = IO.read(:line)
  end

  defp menu_tienda_sobres do
    IO.puts("")
    IO.puts("--- TIENDA Y SOBRES ---")
    IO.puts("  Aquí compras sobres con monedas y los abres para recibir 3 Pokémon.")
    IO.puts("  1) Ver tienda (precios y probabilidades de rareza)")
    IO.puts("  2) Comprar sobre básico")
    IO.puts("  3) Comprar sobre avanzado")
    IO.puts("  4) Abrir el siguiente sobre en cola (recibes 3 Pokémon nuevos)")
    IO.puts("  0) Volver al menú principal (sin hacer nada más)")
    IO.puts("")

    case leer_opcion() do
      "0" -> :ok
      "1" -> ejecutar_y_mostrar("tienda")
      "2" -> ejecutar_y_mostrar("comprar_sobre basico")
      "3" -> ejecutar_y_mostrar("comprar_sobre avanzado")
      "4" -> ejecutar_y_mostrar("abrir_sobre ultimo")
      _ -> IO.puts("Opción no válida.")
    end
  end

  defp menu_equipos do
    IO.puts("")
    IO.puts("--- EQUIPOS (1 a 3 Pokémon) ---")
    IO.puts("  Necesitas un equipo activo antes de iniciar una batalla.")
    IO.puts("  Los números de Pokémon son los que ves en tu inventario (ej. #12).")
    IO.puts("  1) Listar mis equipos guardados")
    IO.puts("  2) Crear equipo nuevo (nombre + ids separados por coma, ej: 1,2,3)")
    IO.puts("  3) Elegir qué equipo usar en la próxima batalla")
    IO.puts("  4) Quitar un Pokémon de un equipo")
    IO.puts("  5) Añadir un Pokémon a un equipo (máximo 3)")
    IO.puts("  0) Volver")
    IO.puts("")

    case leer_opcion() do
      "0" ->
        :ok

      "1" ->
        ejecutar_y_mostrar("listar_equipos")

      "2" ->
        nombre = leer_texto("Nombre del equipo: ")
        ids = leer_texto("Ids de Pokémon (ej: 1,2,3): ")

        if nombre != "" and ids != "" do
          ejecutar_y_mostrar("crear_equipo #{nombre} #{ids}")
        else
          IO.puts("Datos incompletos.")
        end

      "3" ->
        nombre = leer_texto("Nombre del equipo a activar: ")

        if nombre != "" do
          ejecutar_y_mostrar("usar_equipo #{nombre}")
        end

      "4" ->
        nombre = leer_texto("Nombre del equipo: ")
        pid = leer_texto("Id del Pokémon a quitar: ")

        if nombre != "" and pid != "" do
          ejecutar_y_mostrar("quitar_pokemon_equipo #{nombre} #{pid}")
        end

      "5" ->
        nombre = leer_texto("Nombre del equipo: ")
        pid = leer_texto("Id del Pokémon a añadir: ")

        if nombre != "" and pid != "" do
          ejecutar_y_mostrar("agregar_pokemon_equipo #{nombre} #{pid}")
        end

      _ ->
        IO.puts("Opción no válida.")
    end
  end

  defp menu_batalla do
    IO.puts("")
    IO.puts("--- BATALLA (salas S-…) ---")
    IO.puts("  Orden típico: crear o unirse → ambos con equipo activo → iniciar batalla → atacar.")
    IO.puts("  Opción 2 te muestra las salas de batalla activas en este servidor.")
    IO.puts("  1) Crear sala de batalla (recibes un código como S-1001)")
    IO.puts("  2) Ver salas de batalla abiertas ahora")
    IO.puts("  3) Unirse a una sala (escribe el código, ej: S-1001)")
    IO.puts("  4) Iniciar el combate (cuando ya hay 2 jugadores en la sala)")
    IO.puts("  5) Ver estado de la batalla (usa la sala guardada en tu sesión)")
    IO.puts("  6) Atacar (escribe el id del movimiento exacto como en tu inventario)")
    IO.puts("  7) Cambiar de Pokémon activo (id de instancia)")
    IO.puts("  8) Rendirse (pierdes; el rival gana)")
    IO.puts("  0) Volver")
    IO.puts("")

    case leer_opcion() do
      "0" ->
        :ok

      "1" ->
        ejecutar_y_mostrar("crear_sala")

      "2" ->
        ejecutar_y_mostrar("listar_salas")

      "3" ->
        room = leer_texto("Código de sala (ej: S-1001): ")

        if room != "" do
          ejecutar_y_mostrar("unirse_sala #{room}")
        end

      "4" ->
        room = leer_texto("Código de sala: ")

        if room != "" do
          ejecutar_y_mostrar("iniciar_batalla #{room}")
        end

      "5" ->
        ejecutar_y_mostrar("estado_batalla")

      "6" ->
        mov = leer_texto("Id del movimiento (como en inventario): ")

        if mov != "" do
          ejecutar_y_mostrar("ataque #{mov}")
        end

      "7" ->
        pid = leer_texto("Id instancia del Pokémon: ")

        if pid != "" do
          ejecutar_y_mostrar("cambiar #{pid}")
        end

      "8" ->
        ejecutar_y_mostrar("rendirse")

      _ ->
        IO.puts("Opción no válida.")
    end
  end

  defp menu_intercambio do
    IO.puts("")
    IO.puts("--- INTERCAMBIO (salas I-…) ---")
    IO.puts("  Un jugador crea sala y pasa el código; el otro se une.")
    IO.puts("  Ambos ofrecen un Pokémon y confirman para intercambiar.")
    IO.puts("  1) Crear sala de intercambio (te dan un código I-…)")
    IO.puts("  2) Unirse a una sala de intercambio")
    IO.puts("  3) Ofrecer un Pokémon (id que aparece en tu inventario)")
    IO.puts("  4) Confirmar intercambio (los dos deben confirmar)")
    IO.puts("  5) Cancelar intercambio")
    IO.puts("  0) Volver")
    IO.puts("")

    case leer_opcion() do
      "0" ->
        :ok

      "1" ->
        ejecutar_y_mostrar("crear_sala_intercambio")

      "2" ->
        room = leer_texto("Código de sala: ")

        if room != "" do
          ejecutar_y_mostrar("unirse_sala_intercambio #{room}")
        end

      "3" ->
        pid = leer_texto("Id del Pokémon a ofrecer: ")

        if pid != "" do
          ejecutar_y_mostrar("ofrecer_pokemon #{pid}")
        end

      "4" ->
        ejecutar_y_mostrar("confirmar_intercambio")

      "5" ->
        ejecutar_y_mostrar("cancelar_intercambio")

      _ ->
        IO.puts("Opción no válida.")
    end
  end

  defp ejecutar_y_mostrar(comando) do
    IO.puts("")

    case Servidor.comando(comando) do
      {:ok, msg} ->
        IO.puts(msg)

      {:error, msg} ->
        IO.puts("ERROR: " <> msg)
    end
  end

  defp leer_opcion do
    IO.write("> ")

    case IO.read(:line) do
      :eof -> "0"
      line -> line |> String.trim()
    end
  end

  defp leer_texto(etiqueta) do
    IO.write(etiqueta)

    case IO.read(:line) do
      :eof -> ""
      line -> line |> String.trim()
    end
  end
end
