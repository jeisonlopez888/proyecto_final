defmodule PokemonBattle.FormatoConsola do
  @moduledoc false
  alias PokemonBattle.Persistencia

  @doc "Formatea el equipo de un jugador para mostrar en consola."
  def formatear_equipo(usuario, equipo, moves_index) when is_map(equipo) do
    activo_id = equipo.activo_id

    lineas =
      Enum.map(equipo.equipo_ids, fn id ->
        p = equipo.pokemon_por_id[id]
        activo = if id == activo_id, do: " [ACTIVO]", else: ""
        movs = formatear_movimientos(p.movimientos || [], moves_index)

        "    ##{id} #{p.especie} (#{p.tipo}) HP #{p.hp}/#{p.hp_max} | Ataque #{p.ataque} Defensa #{p.defensa} Vel #{p.velocidad}#{activo}\n       Movimientos: #{movs}"
      end)

    "  #{usuario}:\n" <> Enum.join(lineas, "\n")
  end

  def formatear_equipo(_usuario, nil, _idx), do: "  (equipo no cargado)"

  def formatear_movimientos(ids, moves_index) do
    ids
    |> Enum.map(fn mid ->
      m = Map.get(moves_index, to_string(mid))

      if m do
        "#{mid} (#{m["nombre"] || mid}, #{m["tipo"]}, poder #{m["poder"]})"
      else
        to_string(mid)
      end
    end)
    |> Enum.join(" | ")
  end

  def formatear_estado_batalla(estado) when is_map(estado) do
    moves_index = estado[:moves_index] || %{}

    bloque_jugadores =
      (estado[:jugadores] || [])
      |> Enum.map(fn u ->
        eq = get_in(estado, [:equipo_por_usuario, u])
        danio = Map.get(estado[:daño_recibido] || %{}, u, 0)
        eq_txt = formatear_equipo(u, eq, moves_index)
        "  Daño total recibido: #{danio}\n#{eq_txt}"
      end)
      |> Enum.join("\n\n")

    ronda = Map.get(estado, :ronda, 0)
    status = Map.get(estado, :status, "?")

    pendientes = estado[:acciones_pendientes] || %{}

    pend_txt =
      if map_size(pendientes) > 0 do
        "\n  Acciones pendientes: #{inspect(pendientes)}"
      else
        ""
      end

    "=== Estado batalla #{estado[:room_id]} ===\n" <>
      "Estado: #{status} | Ronda: #{ronda}#{pend_txt}\n\n" <> bloque_jugadores
  end

  def formatear_resultado_ronda(meta, moves_index) when is_map(meta) do
    case meta do
      %{estado: :terminada, ganador: g} ->
        "¡Batalla terminada! Ganador: #{g}"

      %{estado: :ronda_resuelta, order: order, acciones: acciones} ->
        orden = Enum.join(order, " → ")
        detalle = formatear_acciones_ronda(acciones, moves_index)
        "Ronda resuelta. Orden de velocidad: #{orden}\n#{detalle}"

      other ->
        "Resultado: #{inspect(other)}"
    end
  end

  defp formatear_acciones_ronda(acciones, moves_index) when is_map(acciones) do
    acciones
    |> Enum.map(fn {u, acc} ->
      case acc do
        {:ataque, mov_id} ->
          m = Map.get(moves_index, mov_id)
          nom = if m, do: m["nombre"] || mov_id, else: mov_id
          "  #{u}: atacó con #{nom} (#{mov_id})"

        {:cambiar, pid} ->
          "  #{u}: cambió al Pokémon ##{pid}"

        {:pasar, _} ->
          "  #{u}: perdió el turno (tiempo agotado)"

        _ ->
          "  #{u}: #{inspect(acc)}"
      end
    end)
    |> Enum.join("\n")
  end

  def formatear_salas_disponibles(salas) when is_list(salas) do
    if salas == [] do
      "No hay salas de batalla abiertas en este servidor."
    else
      header =
        "=== Salas disponibles ===\n" <>
          "Código      Estado                    Jugadores\n"

      filas =
        salas
        |> Enum.map(fn s ->
          id = s[:room_id] || s["room_id"]
          st = etiqueta_estado(s[:status] || s["status"])
          jug = formatear_jugadores(s)
          "#{String.pad_trailing(to_string(id), 12)}#{String.pad_trailing(st, 26)}#{jug}"
        end)
        |> Enum.join("\n")

      header <> filas <> "\n\nUsa: unirse_sala <código>  (ej: unirse_sala S-1001)"
    end
  end

  defp etiqueta_estado(:esperando_jugador2), do: "Esperando oponente"
  defp etiqueta_estado(:lista_para_iniciar), do: "Lista (2 jugadores)"
  defp etiqueta_estado(:en_progreso), do: "En combate"
  defp etiqueta_estado(:terminada), do: "Terminada"
  defp etiqueta_estado(other), do: to_string(other)

  defp formatear_jugadores(%{jugadores: jugadores, jugador1: j1}) when is_list(jugadores) do
    j2 = Enum.find(jugadores, fn j -> j != j1 end)
    j2txt = if j2, do: j2, else: "(esperando...)"
    "#{j1} vs #{j2txt}"
  end

  defp formatear_jugadores(_), do: "?"

  def cargar_moves_index do
    moves = Persistencia.catalogo_movimientos()
    por_tipo = moves["por_tipo"] || %{}
    globales = moves["globales"] || []

    (por_tipo |> Map.values() |> List.flatten()) ++ globales
    |> Map.new(fn m -> {to_string(m["id"]), m} end)
  end
end
