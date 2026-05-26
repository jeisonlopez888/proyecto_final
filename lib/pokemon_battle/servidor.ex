defmodule PokemonBattle.Servidor do
  @moduledoc """
  **Interfaz de consola** del juego (`GenServer` registrado como `PokemonBattle.Servidor`).

  Mantiene sesión: usuario logueado, sala de batalla o intercambio “actual” para atajos de comandos.
  Cada línea de texto se tokeniza y se traduce a llamadas a `GestorEntrenadores`, `SistemaSobres`, `GestorSalas` y `Persistencia`.
  Las respuestas son cadenas en español listas para mostrar al jugador.

  Para dos jugadores en la misma consola `iex`, conviene usar `GestorSalas.ataque/3` pasando el nombre de usuario explícito.
  """

  use GenServer

  alias PokemonBattle.GestorEntrenadores
  alias PokemonBattle.SistemaSobres
  alias PokemonBattle.GestorSalas
  alias PokemonBattle.Persistencia
  alias PokemonBattle.FormatoConsola

  defstruct usuario_actual: nil,
            sala_batalla_actual: nil,
            sala_intercambio_actual: nil

  # =========================
  # API
  # =========================

  @doc "Arranca el proceso del servidor de consola con nombre registrado `PokemonBattle.Servidor`."
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Procesa un comando de consola en texto.

  Devuelve una respuesta en español para el usuario.
  """
  def comando(texto) when is_binary(texto) do
    GenServer.call(__MODULE__, {:comando, texto})
  end

  # =========================
  # GenServer
  # =========================

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_info({:batalla_evento, room_id, mensaje}, state) do
    IO.puts("")
    IO.puts("[#{room_id}] #{mensaje}")
    IO.puts("")
    {:noreply, state}
  end

  @impl true
  def handle_call({:comando, texto}, _from, state) do
    tokens = parse_tokens(texto)

    cond do
      tokens == [] ->
        {:reply, {:error, :comando_vacio}, state}

      match?([_ | _], tokens) and hd(tokens) == "iniciar" and length(tokens) == 3 ->
        ["iniciar", usuario, clave] = tokens

        case GestorEntrenadores.iniciar(usuario, clave) do
          {:ok, _trainer, :registrado} ->
            nodo_msg =
              case PokemonBattle.NodoEntrenador.al_iniciar_sesion(usuario) do
                {:ok, extra} -> "\n#{extra}"
                _ -> ""
              end

            {:reply,
             {:ok,
              "Sesión iniciada como #{usuario}. ¡Bienvenido! Tienes 1 sobre básico gratis en cola. " <>
                "Ábrelo con el menú «Tienda y sobres» (opción 4) o el comando `abrir_sobre ultimo`.#{nodo_msg}"},
             %{state | usuario_actual: to_string(usuario)}}

          {:ok, _trainer, :existente} ->
            nodo_msg =
              case PokemonBattle.NodoEntrenador.al_iniciar_sesion(usuario) do
                {:ok, extra} -> "\n#{extra}"
                _ -> ""
              end

            {:reply, {:ok, "Sesión iniciada como #{usuario}.#{nodo_msg}"},
             %{state | usuario_actual: to_string(usuario)}}

          {:error, reason} ->
            {:reply, {:error, "No se pudo iniciar sesión: #{razon_a_str(reason)}"}, state}
        end

      tokens == ["salir"] ->
        {:reply, {:ok, "Sesión cerrada."}, %{state | usuario_actual: nil, sala_batalla_actual: nil, sala_intercambio_actual: nil}}

      tokens == ["perfil"] ->
        con_usuario(state, fn usuario ->
          case GestorEntrenadores.perfil(usuario) do
            %{} = perfil ->
              n = perfil["sobres_sin_abrir"] || 0
              inv = length(perfil["inventario_pokemon_ids"] || [])
              der = perfil["derrotas"] || 0
              acum = perfil["monedas_acumuladas"] || 0
              eq = perfil["equipo_activo"]

              eq_txt =
                if eq == nil or eq == "", do: "(ninguno — elige uno en Equipos)", else: to_string(eq)

              {:ok,
               "=== Perfil de #{usuario} ===\n" <>
                 "Monedas actuales: #{perfil["monedas"] || 0}\n" <>
                 "Monedas ganadas en total (histórico): #{acum}\n" <>
                 "Sobres sin abrir (contador): #{n}\n" <>
                 "Pokémon en inventario: #{inv}\n" <>
                 "Victorias: #{perfil["victorias"] || 0} | Derrotas: #{der}\n" <>
                 "Equipo activo para batalla: #{eq_txt}"}

            {:error, reason} ->
              {:error, "Perfil: #{razon_a_str(reason)}"}
          end
        end)

      tokens == ["inventario"] ->
        con_usuario(state, fn usuario ->
          case GestorEntrenadores.inventario(usuario) do
            {:ok, %{pokemon: pokemon}} ->
              cat = Persistencia.catalogo_especies()
              movs = Persistencia.catalogo_movimientos()
              idx = indice_movimientos(movs)

              lineas =
                pokemon
                |> Enum.with_index(1)
                |> Enum.map(fn {p, i} ->
                  fmt_inventario_linea(i, usuario, p, cat, idx)
                end)

              {:ok, "=== Inventario de #{usuario} (#{length(pokemon)} Pokémon) ===\n\n" <> Enum.join(lineas, "\n\n")}

            {:error, reason} ->
              {:error, "Inventario: #{razon_a_str(reason)}"}
          end
        end)

      tokens == ["clasificacion"] ->
        con_usuario(state, fn _usuario ->
          case GestorEntrenadores.clasificacion() do
            {:ok, ranking} ->
              header = "=== Clasificación global ===\n#  Entrenador            Victorias  Monedas acum.\n"

              filas =
                ranking
                |> Enum.take(20)
                |> Enum.with_index(1)
                |> Enum.map(fn {x, i} ->
                  ac = x[:monedas_acumuladas] || 0
                  u = to_string(x[:usuario]) |> String.slice(0, 16) |> String.pad_trailing(16)

                  "#{String.pad_leading(to_string(i), 2)}  #{u}  #{String.pad_leading(to_string(x[:victorias]), 9)}  #{String.pad_leading(to_string(ac), 12)}"
                end)
                |> Enum.join("\n")

              {:ok, header <> filas}
          end
        end)

      tokens == ["tienda"] ->
        case SistemaSobres.tienda() do
          {:ok, tienda} ->
            bloques =
              tienda
              |> Map.to_list()
              |> Enum.sort_by(&elem(&1, 0))
              |> Enum.map(fn {k, v} ->
                nom = v["nombre"] || k
                p = v["precio"] || 0
                c = v["comun"] || 0
                r = v["raro"] || 0
                e = v["epico"] || 0
                "- #{nom} (#{k}): #{p} monedas | común #{c}% | raro #{r}% | épico #{e}%"
              end)
              |> Enum.join("\n")

            {:reply, {:ok, "=== Tienda ===\n" <> bloques}, state}
        end

      match?([_ , _], tokens) and hd(tokens) == "comprar_sobre" and length(tokens) == 2 ->
        ["comprar_sobre", tipo] = tokens

        con_usuario(state, fn usuario ->
          case SistemaSobres.comprar_sobre(usuario, tipo) do
            {:ok, meta} ->
              {:ok, "Compra exitosa: #{meta[:sobre]} por #{meta[:precio]} monedas. Recibiste 1 sobre."}

            {:error, reason} ->
              {:error, "Compra fallida: #{razon_a_str(reason)}"}
          end
        end)

      match?([_, _], tokens) and hd(tokens) == "abrir_sobre" and length(tokens) == 2 ->
        ["abrir_sobre", id_or_ultimo] = tokens

        con_usuario(state, fn usuario ->
          case SistemaSobres.abrir_sobre(usuario, id_or_ultimo) do
            {:ok, %{pokemon_ids: ids}} ->
              cat = Persistencia.catalogo_especies()
              movs = Persistencia.catalogo_movimientos()
              idx = indice_movimientos(movs)

              bloques =
                ids
                |> Enum.with_index(1)
                |> Enum.map(fn {pid, n} ->
                  p = Persistencia.obtener_instancia(pid)
                  String.trim_leading(fmt_inventario_linea(n, usuario, p, cat, idx))
                end)
                |> Enum.join("\n\n")

              {:ok, "¡Sobre abierto! Obtuviste:\n\n" <> bloques}

            {:error, reason} ->
              {:error, "No se pudo abrir el sobre: #{razon_a_str(reason)}"}
          end
        end)

      length(tokens) >= 1 and hd(tokens) == "crear_sala" ->
        con_usuario(state, fn usuario ->
          opts =
            Enum.reduce(Enum.drop(tokens, 1), [caller_pid: self()], fn t, acc ->
              case String.split(t, "=", parts: 2) do
                ["tiempo_turno", n] ->
                  case Integer.parse(String.trim(n)) do
                    {sec, _} -> Keyword.put(acc, :tiempo_turno_ms, sec * 1000)
                    _ -> acc
                  end

                _ ->
                  acc
              end
            end)

          case GestorSalas.crear_sala(usuario, opts) do
            {:ok, room_id} ->
              s = div(Keyword.get(opts, :tiempo_turno_ms, 30_000), 1000)
              equipo_txt = texto_equipo_activo(usuario)

              msg =
                "Sala de batalla creada: #{room_id}\n" <>
                  "Tiempo por turno: #{s}s | Espera máxima de oponente: 3 min\n" <>
                  "Comparte el código con otro entrenador.\n\n" <>
                  "=== Tu equipo ===\n#{equipo_txt}\n\n" <>
                  "(Cuando se una un oponente, la batalla comenzará automáticamente.)"

              {:reply, {:ok, msg}, %{state | sala_batalla_actual: room_id}}

            {:error, reason} ->
              {:reply, {:error, "No se pudo crear la sala: #{razon_a_str(reason)}"}, state}
          end
        end)

      tokens == ["listar_salas"] ->
        con_usuario(state, fn _ ->
          case GestorSalas.listar_salas() do
            {:ok, salas} ->
              disponibles =
                Enum.filter(salas, fn s -> s.status == :esperando_jugador2 end)

              if disponibles == [] and salas == [] do
                {:ok, "No hay salas de batalla abiertas."}
              else
                lista = if disponibles != [], do: disponibles, else: salas
                {:ok, FormatoConsola.formatear_salas_disponibles(lista)}
              end

            {:error, reason} ->
              {:error, "No se pudo listar: #{razon_a_str(reason)}"}
          end
        end)

      match?([_, _], tokens) and hd(tokens) == "unirse_sala" and length(tokens) == 2 ->
        ["unirse_sala", room_id] = tokens

        con_usuario(state, fn usuario ->
          case GestorSalas.unirse_sala(room_id, usuario, self()) do
            {:ok, :unido} ->
              {:reply,
               {:ok,
                "Unido a la sala #{room_id}. La batalla se inició automáticamente.\n" <>
                  "Recibirás en pantalla los equipos y el avance del combate."},
               %{state | sala_batalla_actual: room_id}}

            {:error, reason} ->
              {:reply, {:error, "No se pudo unir a la sala: #{razon_a_str(reason)}"}, state}
          end
        end)

      match?([_, _], tokens) and hd(tokens) == "iniciar_batalla" and length(tokens) == 2 ->
        ["iniciar_batalla", room_id] = tokens

        con_usuario(state, fn usuario ->
          case GestorSalas.iniciar_batalla(room_id, usuario) do
            {:ok, %{resumen: resumen}} when is_map(resumen) ->
              {:reply,
               {:ok,
                "Batalla iniciada en #{room_id}.\n\n" <>
                  FormatoConsola.formatear_estado_batalla(resumen) <>
                  "\n\nComandos: ataque <mov>, cambiar <id>, rendirse."},
               %{state | sala_batalla_actual: room_id}}

            {:ok, _} ->
              case GestorSalas.obtener_batalla_estado(room_id) do
                %{} = e ->
                  {:reply,
                   {:ok,
                    "Batalla en curso en #{room_id}.\n\n" <>
                      FormatoConsola.formatear_estado_batalla(e) <>
                      "\n\nComandos: ataque <mov>, cambiar <id>, rendirse."},
                   %{state | sala_batalla_actual: room_id}}

                _ ->
                  {:reply, {:ok, "Batalla iniciada en #{room_id}."},
                   %{state | sala_batalla_actual: room_id}}
              end

            {:error, reason} ->
              {:reply, {:error, "No se pudo iniciar: #{razon_a_str(reason)}"}, state}
          end
        end)

      tokens == ["estado_batalla"] ->
        con_usuario(state, fn _usuario ->
          case state.sala_batalla_actual do
            nil ->
              {:error, "No hay sala de batalla activa en esta sesión."}

            room_id ->
              case GestorSalas.obtener_batalla_estado(room_id) do
                %{} = e ->
                  {:ok, FormatoConsola.formatear_estado_batalla(e)}

                {:error, r} ->
                  {:error, razon_a_str(r)}
              end
          end
        end)

      match?([_, _], tokens) and hd(tokens) == "ataque" and length(tokens) == 2 ->
        ["ataque", mov_id] = tokens

        case state.sala_batalla_actual do
          nil ->
            {:reply, {:error, "Debes crear o unirte a una sala de batalla primero."}, state}

          room_id ->
            con_usuario(state, fn usuario ->
              case GestorSalas.ataque(room_id, usuario, mov_id) do
                {:ok, :esperando_oponente} ->
                  {:reply, {:ok, "Ataque #{mov_id} registrado. Esperando acción del oponente…"}, state}

                {:ok, meta} ->
                  idx = FormatoConsola.cargar_moves_index()

                  {:reply,
                   {:ok,
                    "Ataque #{mov_id} registrado.\n" <>
                      FormatoConsola.formatear_resultado_ronda(meta, idx)},
                   state}

                {:error, reason} ->
                  {:reply, {:error, "Ataque fallido: #{razon_a_str(reason)}"}, state}
              end
            end)
        end

      match?([_, _], tokens) and hd(tokens) == "cambiar" and length(tokens) == 2 ->
        ["cambiar", pokemon_id] = tokens

        case state.sala_batalla_actual do
          nil ->
            {:reply, {:error, "Debes crear o unirte a una sala de batalla primero."}, state}

          room_id ->
            con_usuario(state, fn usuario ->
              case GestorSalas.cambiar(room_id, usuario, pokemon_id) do
                {:ok, :esperando_oponente} ->
                  {:reply, {:ok, "Cambio a ##{pokemon_id} registrado. Esperando al oponente…"}, state}

                {:ok, meta} ->
                  idx = FormatoConsola.cargar_moves_index()

                  {:reply,
                   {:ok,
                    "Cambio registrado.\n" <> FormatoConsola.formatear_resultado_ronda(meta, idx)},
                   state}

                {:error, reason} ->
                  {:reply, {:error, "Cambio fallido: #{razon_a_str(reason)}"}, state}
              end
            end)
        end

      tokens == ["rendirse"] ->
        con_usuario(state, fn usuario ->
          case state.sala_batalla_actual do
            nil ->
              {:reply, {:error, "No hay sala activa."}, state}

            room_id ->
              case GestorSalas.rendirse(room_id, usuario) do
                {:ok, %{ganador: ganador}} ->
                  {:reply, {:ok, "Te rendiste. Ganador: #{ganador}."}, state}

                {:error, reason} ->
                  {:reply, {:error, "No se pudo rendir: #{razon_a_str(reason)}"}, state}
              end
          end
        end)

      length(tokens) >= 3 and hd(tokens) == "crear_equipo" ->
        ["crear_equipo", nombre | id_parts] = tokens

        pokemon_ids =
          id_parts
          |> Enum.join(",")
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        con_usuario(state, fn usuario ->
          case GestorEntrenadores.crear_equipo(usuario, nombre, pokemon_ids) do
            :ok -> {:ok, "Equipo #{nombre} creado."}
            {:error, reason} -> {:error, "No se pudo crear el equipo: #{razon_a_str(reason)}"}
          end
        end)

      match?([_, _], tokens) and hd(tokens) == "usar_equipo" and length(tokens) == 2 ->
        ["usar_equipo", nombre] = tokens

        con_usuario(state, fn usuario ->
          case GestorEntrenadores.usar_equipo(usuario, nombre) do
            {:ok, _} -> {:reply, {:ok, "Equipo activo: #{nombre}."}, state}
            {:error, reason} -> {:reply, {:error, "No se pudo usar el equipo: #{razon_a_str(reason)}"}, state}
          end
        end)

      tokens == ["listar_equipos"] ->
        con_usuario(state, fn usuario ->
          case GestorEntrenadores.listar_equipos(usuario) do
            {:ok, equipos} when map_size(equipos) == 0 ->
              {:ok, "No tienes equipos guardados."}

            {:ok, equipos} ->
              cat = Persistencia.catalogo_especies()

              lineas =
                Enum.map(equipos, fn {nombre, ids} ->
                  n = length(ids)
                  partes =
                    Enum.map(ids, fn id ->
                      p = Persistencia.obtener_instancia(id)
                      esp = (p && p["especie"]) || "?"
                      ed = cat[esp] || %{}
                      tipo = ed["tipo"] || ed["tipos"] || "?"
                      tstr = if is_list(tipo), do: Enum.join(tipo, "/"), else: tipo
                      "[##{id}] #{esp} (#{tstr})"
                    end)

                  "  #{nombre}   [#{n}/3]: #{Enum.join(partes, ", ")}"
                end)

              {:ok, "Equipos guardados:\n" <> Enum.join(lineas, "\n")}

            {:error, r} ->
              {:error, razon_a_str(r)}
          end
        end)

      match?([_, _ | _], tokens) and hd(tokens) == "quitar_pokemon_equipo" and length(tokens) == 3 ->
        ["quitar_pokemon_equipo", nombre, pid] = tokens

        con_usuario(state, fn usuario ->
          case GestorEntrenadores.quitar_pokemon_equipo(usuario, nombre, pid) do
            :ok -> {:ok, "Pokémon quitado del equipo #{nombre}."}
            {:error, r} -> {:error, razon_a_str(r)}
          end
        end)

      match?([_, _ | _], tokens) and hd(tokens) == "agregar_pokemon_equipo" and length(tokens) == 3 ->
        ["agregar_pokemon_equipo", nombre, pid] = tokens

        con_usuario(state, fn usuario ->
          case GestorEntrenadores.agregar_pokemon_equipo(usuario, nombre, pid) do
            :ok -> {:ok, "Pokémon agregado al equipo #{nombre}."}
            {:error, r} -> {:error, razon_a_str(r)}
          end
        end)

      tokens == ["crear_sala_intercambio"] ->
        con_usuario(state, fn usuario ->
          case GestorSalas.crear_sala_intercambio(usuario, caller_pid: self()) do
            {:ok, room_id} ->
              {:reply, {:ok, "[Sala #{room_id} creada] Comparte este código con el otro entrenador."},
               %{state | sala_intercambio_actual: room_id}}

            {:error, r} ->
              {:reply, {:error, razon_a_str(r)}, state}
          end
        end)

      match?([_, _], tokens) and hd(tokens) == "unirse_sala_intercambio" and length(tokens) == 2 ->
        ["unirse_sala_intercambio", room_id] = tokens

        con_usuario(state, fn usuario ->
          case GestorSalas.unirse_sala_intercambio(room_id, usuario, self()) do
            {:ok, :unido} ->
              {:reply, {:ok, "[Sala #{room_id}] Entraste. Ya pueden intercambiar."},
               %{state | sala_intercambio_actual: GestorSalas.normalizar_id_sala(room_id)}}

            {:error, r} ->
              {:reply, {:error, razon_a_str(r)}, state}
          end
        end)

      match?([_, _], tokens) and hd(tokens) == "ofrecer_pokemon" and length(tokens) == 2 ->
        ["ofrecer_pokemon", pid] = tokens

        con_usuario(state, fn usuario ->
          rid = state.sala_intercambio_actual

          if rid == nil do
            {:reply, {:error, "No estás en una sala de intercambio."}, state}
          else
            case GestorSalas.ofrecer_pokemon_intercambio(rid, usuario, pid) do
              {:ok, m} -> {:reply, {:ok, "Oferta registrada: #{inspect(m)}"}, state}
              {:error, r} -> {:reply, {:error, razon_a_str(r)}, state}
            end
          end
        end)

      tokens == ["confirmar_intercambio"] ->
        con_usuario(state, fn usuario ->
          rid = state.sala_intercambio_actual

          if rid == nil do
            {:reply, {:error, "No hay sala de intercambio activa."}, state}
          else
            case GestorSalas.confirmar_intercambio(rid, usuario) do
              {:ok, %{intercambiado: true}} ->
                {:reply, {:ok, "Intercambio completado."}, %{state | sala_intercambio_actual: nil}}

              {:ok, other} ->
                {:reply, {:ok, "Estado: #{inspect(other)}"}, state}

              {:error, r} ->
                {:reply, {:error, razon_a_str(r)}, state}
            end
          end
        end)

      tokens == ["cancelar_intercambio"] ->
        con_usuario(state, fn usuario ->
          rid = state.sala_intercambio_actual

          if rid == nil do
            {:reply, {:error, "No hay sala de intercambio activa."}, state}
          else
            case GestorSalas.cancelar_intercambio(rid, usuario) do
              {:ok, _} ->
                {:reply, {:ok, "Intercambio cancelado."}, %{state | sala_intercambio_actual: nil}}

              {:error, r} ->
                {:reply, {:error, razon_a_str(r)}, state}
            end
          end
        end)

      # Comando desconocido
      true ->
        {:reply, {:error, "Comando no reconocido: #{texto}"}, state}
    end
  end

  # =========================
  # Helpers
  # =========================

  defp indice_movimientos(movs) do
    por = movs["por_tipo"] || %{}
    glob = movs["globales"] || []
    todos = por |> Map.values() |> List.flatten() |> Kernel.++(glob)
    Map.new(todos, fn m -> {to_string(m["id"]), m} end)
  end

  defp fmt_inventario_linea(i, usuario, p, cat, idx) do
    id = p["id"]
    esp = p["especie"] || "?"
    ed = cat[esp] || %{}

    tipo_str =
      cond do
        is_list(ed["tipos"]) -> Enum.join(ed["tipos"], "/")
        is_binary(ed["tipo"]) && String.contains?(ed["tipo"], "/") -> ed["tipo"]
        ed["tipo"] -> ed["tipo"]
        true -> "?"
      end

    rareza = p["rareza"] || "comun"

    mov_str =
      (p["movimientos"] || [])
      |> Enum.map(fn mid ->
        m = idx[to_string(mid)]
        if m, do: "#{mid}(#{m["poder"]})", else: "#{mid}(?)"
      end)
      |> Enum.join(", ")

    du = p["dueño_original"] || usuario

    "  #{i}. [#{id}] #{esp} (#{tipo_str}) [#{rareza}]\n     Ataque: #{p["ataque"]} | Defensa: #{p["defensa"]} | Velocidad: #{p["velocidad"]} | Salud máx: 100\n     Dueño original: #{du}\n     Movimientos: #{mov_str}"
  end

  defp parse_tokens(texto) do
    texto
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
  end

  defp con_usuario(%__MODULE__{usuario_actual: nil} = state, _fun) do
    {:reply, {:error, "Debes iniciar sesión con `iniciar <usuario> <clave>` primero."}, state}
  end

  defp con_usuario(%__MODULE__{usuario_actual: usuario} = state, fun) do
    case fun.(usuario) do
      {:reply, _, _} = rep -> rep
      {:ok, msg} -> {:reply, {:ok, msg}, state}
      {:error, msg} -> {:reply, {:error, msg}, state}
      other -> {:reply, other, state}
    end
  end

  defp razon_a_str(:clave_incorrecta), do: "clave incorrecta"
  defp razon_a_str(:no_existe), do: "el entrenador no existe"
  defp razon_a_str(:sobre_inexistente), do: "sobre inexistente"
  defp razon_a_str(:saldo_insuficiente), do: "monedas insuficientes"
  defp razon_a_str(:no_hay_sobres), do: "no hay sobres sin abrir"
  defp razon_a_str(:nombre_equipo_ocupado), do: "ya existe un equipo con ese nombre"
  defp razon_a_str(:equipo_inexistente), do: "equipo inexistente"
  defp razon_a_str(:equipo_minimo_un_pokemon), do: "el equipo debe tener al menos un Pokémon"
  defp razon_a_str(:equipo_lleno), do: "el equipo ya tiene 3 Pokémon"
  defp razon_a_str(:pokemon_no_en_equipo), do: "ese Pokémon no está en el equipo"
  defp razon_a_str(:pokemon_duplicado_en_equipo), do: "Pokémon duplicado en el equipo"
  defp razon_a_str(:sala_no_existe),
    do:
      "esa sala no existe en ningún nodo conectado. Comprueba el código, que el otro jugador tenga sesión iniciada en otra terminal y que ambos vean el mensaje de nodo de red al entrar."

  defp razon_a_str({:rpc, reason}), do: "error RPC al nodo del gestor: #{inspect(reason)}"

  defp razon_a_str(:batalla_terminada), do: "la batalla ya terminó"
  defp razon_a_str(:ya_iniciada), do: "la batalla ya está en curso o terminó"
  defp razon_a_str(other), do: to_string(other)

  defp texto_equipo_activo(usuario) do
    case GestorEntrenadores.perfil(usuario) do
      %{} = perfil ->
        equipos = perfil["equipos"] || %{}
        activo = perfil["equipo_activo"]
        idx = FormatoConsola.cargar_moves_index()
        cat = Persistencia.catalogo_especies()

        ids =
          cond do
            activo && Map.has_key?(equipos, activo) -> equipos[activo]
            map_size(equipos) > 0 -> equipos |> Map.values() |> hd()
            true -> []
          end

        if ids == [] or ids == nil do
          "(Sin equipo activo — crea uno en el menú Equipos)"
        else
          ids
          |> Enum.map(fn id ->
            p = Persistencia.obtener_instancia(id)
            esp = (p && p["especie"]) || "?"
            ed = cat[esp] || %{}

            tipo_str =
              cond do
                is_list(ed["tipos"]) -> Enum.join(ed["tipos"], "/")
                ed["tipo"] -> ed["tipo"]
                true -> "?"
              end

            movs = FormatoConsola.formatear_movimientos((p && p["movimientos"]) || [], idx)

            "  ##{id} #{esp} (#{tipo_str}) Ataque #{p["ataque"]} Defensa #{p["defensa"]} Vel #{p["velocidad"]}\n     Movimientos: #{movs}"
          end)
          |> Enum.join("\n")
        end

      _ ->
        "(No se pudo cargar el equipo)"
    end
  end
end

