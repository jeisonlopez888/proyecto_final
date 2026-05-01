# Documentación del proyecto — Batallas Pokémon (Elixir)

Este documento describe **para qué sirve cada módulo** y **qué hace cada función pública** del código. Complementa los `@moduledoc` y `@doc` en los archivos `.ex`.

**Verificación:** `mix test` o `mix proyecto.verify` (misma suite). En el README, la tabla *Tests y verificación de requisitos* enlaza cada requisito con el archivo de prueba correspondiente.

---

## Aplicación OTP

### `ProyectoPokemon.Application`

| Función | Qué hace y para qué sirve |
|---------|---------------------------|
| `start/2` | Arranca la aplicación: crea el supervisor con hijos `Persistencia`, `SupervisorBatallas`, `GestorSalas`, `Servidor`; luego intenta conectar nodos con `Cluster.conectar_desde_env/0`. |

### `ProyectoPokemon`

Módulo raíz del paquete Mix (plantilla). No participa en la lógica del juego.

---

## `PokemonBattle.Persistencia` (GenServer)

**Propósito:** único proceso que lee y escribe JSON en disco; evita corrupción por escrituras concurrentes.

| Función | Qué hace y para qué sirve |
|---------|---------------------------|
| `start_link/1` | Inicia el GenServer registrado como `PokemonBattle.Persistencia`. |
| `data_dir/0` | Devuelve la ruta del directorio `data/` (desde `config`). |
| `hash_clave/1` | Calcula SHA-256 en Base64 de una contraseña (no guardar texto plano). |
| `verificar_clave?/2` | Comprueba si una clave coincide con el hash almacenado. |
| `obtener_entrenador/1` | Lee el mapa del entrenador o `nil`. |
| `guardar_entrenador/2` | Fusiona atributos en el entrenador y persiste `trainers.json`. |
| `listar_entrenadores/0` | Mapa de todos los usuarios y sus datos. |
| `inventario_pokemon/1` | `{:ok, [ids]}` de instancias en inventario del usuario. |
| `agregar_al_inventario/2` | Añade id de Pokémon al inventario del entrenador. |
| `quitar_del_inventario/2` | Quita id del inventario (p. ej. intercambio). |
| `sobres_sin_abrir/1` | Número de sobres pendientes (campo numérico legado). |
| `ajustar_sobres/2` | Suma o resta al contador de sobres. |
| `push_sobre_cola/2` | Encola un sobre comprado (clave de tienda, ej. `sobre_basico`). |
| `pop_sobre_cola/1` | Saca el siguiente sobre de la cola FIFO; error si vacío. |
| `listar_equipos/1` | `{:ok, %{nombre => [ids]}}` de equipos guardados. |
| `guardar_equipo/3` | Crea equipo (1–3 ids, nombre único, ids en inventario). |
| `eliminar_equipo/2` | Borra un equipo por nombre. |
| `equipo_quitar_pokemon/3` | Quita un Pokémon del equipo (no puede quedar vacío). |
| `equipo_agregar_pokemon/3` | Añade Pokémon al equipo si hay hueco (<3) y está en inventario. |
| `crear_instancia_pokemon/1` | Crea instancia en `pokemon.json`, asigna `id` incremental. |
| `obtener_instancia/1` | Mapa de la instancia o `nil`. |
| `actualizar_instancia/2` | Aplica función al mapa de instancia y guarda. |
| `catalogo_especies/0` | Mapa especie → datos base (tipos, stats base). |
| `catalogo_movimientos/0` | Contenido de `moves.json` (por tipo + globales). |
| `catalogo_tienda/0` | Contenido de `tienda.json`. |
| `ajustar_monedas/2` | Suma/resta monedas; si delta > 0, incrementa `monedas_acumuladas`. |
| `agregar_historial/2` | Añade entrada al historial del entrenador. |
| `append_battle_log/1` | Añade una línea a `battles.log` (asíncrono, cast). |

---

## `PokemonBattle.GestorEntrenadores`

**Propósito:** reglas de negocio de cuenta, perfil, ranking y equipos (delega en `Persistencia`).

| Función | Qué hace y para qué sirve |
|---------|---------------------------|
| `iniciar/2` | Login o registro automático con 1 sobre básico en cola. |
| `perfil/1` | Mapa del entrenador o `{:error, :no_existe}`. |
| `inventario/1` | `{:ok, %{pokemon_ids, pokemon}}` con instancias completas. |
| `clasificacion/0` | `{:ok, lista}` ordenada por victorias y monedas acumuladas. |
| `crear_equipo/3` | Crea equipo con nombre único. |
| `listar_equipos/1` | Lista equipos del usuario. |
| `quitar_pokemon_equipo/3` | Quita Pokémon de un equipo guardado. |
| `agregar_pokemon_equipo/3` | Añade Pokémon a un equipo guardado. |
| `usar_equipo/2` | Marca `equipo_activo` para la próxima batalla. |

---

## `PokemonBattle.ComandosBasicos`

**Propósito:** capa simplificada para usar el proyecto con funciones fáciles (nivel principiante), delegando internamente al `Servidor`.

| Función | Qué hace y para qué sirve |
|---------|---------------------------|
| `iniciar/2` | Inicia sesión o registra automáticamente usando texto de comando por dentro. |
| `salir/0` | Cierra la sesión actual. |
| `perfil/0` | Consulta perfil del usuario logueado. |
| `inventario/0` | Muestra inventario del usuario logueado. |
| `tienda/0` | Muestra catálogo de sobres y probabilidades. |
| `comprar_sobre/1` | Compra sobre por tipo (`basico`, `avanzado`). |
| `abrir_sobre/0` | Abre el próximo sobre pendiente. |
| `crear_equipo/2` | Crea equipo a partir de lista de IDs (convierte a string CSV). |
| `usar_equipo/1` | Marca equipo activo. |
| `crear_sala/0` | Crea sala de batalla. |
| `unirse_sala/1` | Une usuario logueado a una sala. |
| `iniciar_batalla/1` | Inicia combate en la sala. |
| `ataque/1` | Envía ataque con id de movimiento. |
| `cambiar/1` | Solicita cambio de Pokémon por id de instancia. |
| `ayuda/0` | Devuelve lista de comandos básicos en texto. |
| `comandos_principiante/0` | Lista de comandos de práctica (para usar con `Enum`). |

---

## `PokemonBattle.SistemaSobres`

**Propósito:** compra y apertura de sobres; generación de Pokémon según rareza y movimientos.

| Función | Qué hace y para qué sirve |
|---------|---------------------------|
| `tienda/0` | `{:ok, mapa}` del catálogo de tienda. |
| `comprar_sobre/2` | Cobra precio y encola el tipo de sobre (`basico` → `sobre_basico`). |
| `abrir_sobre/2` | Desencola un sobre, genera 3 Pokémon, los guarda y los añade al inventario. |

---

## `PokemonBattle.MotorCombate`

**Propósito:** cálculo puro de daño, efectividad de tipos y STAB (sin estado).

| Función | Qué hace y para qué sirve |
|---------|---------------------------|
| `normalizar_tipo/1` | Unifica strings de tipo para comparar (minúsculas, sin acentos). |
| `fuerte_contra?/2` | ¿El tipo del movimiento es superefectivo contra el tipo defensor? |
| `efectividad_un_tipo/2` | Factor ×2, ×0.5 o ×1 para un solo tipo defensor. |
| `efectividad_total/2` | Producto de factores si el defensor tiene varios tipos. |
| `stab/2` | 1.5 si el tipo del movimiento coincide con algún tipo del atacante. |
| `calcular_dano/6` | Fórmula final de daño con mínimo 1. |
| `random_factor/2` | Aleatorio entre 0.85 y 1.0 (o rango dado). |
| `calcular_dano_movimiento/4` | Orquesta movimiento + maps atacante/defensor + opciones (`:random_factor`). |

---

## `PokemonBattle.SupervisorBatallas`

**Propósito:** `DynamicSupervisor` que arranca procesos `Batalla` bajo demanda.

| Función | Qué hace y para qué sirve |
|---------|---------------------------|
| `start_link/1` | Inicia el supervisor con nombre registrado. |
| `start_batalla/1` | Añade un hijo `PokemonBattle.Batalla` con los argumentos de la sala. |
| `listar_batallas/0` | Lista de `pid` de batallas activas (depuración/tests). |

---

## `PokemonBattle.Batalla` (GenServer por sala)

**Propósito:** estado y lógica de una partida 1v1 (turnos simultáneos, HP, fin de partida).

| Función | Qué hace y para qué sirve |
|---------|---------------------------|
| `unirse/3` | Segundo jugador entra en la sala; opcional `caller_pid` para monitorizar. |
| `iniciar/2` | Carga equipos desde persistencia e inicia combate. |
| `ataque/3` | Registra ataque de un jugador; resuelve turno si ya hay dos acciones. |
| `cambiar/3` | Registra cambio de Pokémon activo. |
| `rendirse/2` | Termina la batalla a favor del oponente y reparte recompensas. |
| `obtener_ultimo_orden/1` | Orden de actuación por velocidad en el último turno resuelto. |
| `obtener_estado/1` | Mapa resumido de estado (tests / consola). |

---

## `PokemonBattle.GestorSalas` (GenServer)

**Propósito:** registro global `id_sala → pid` de batallas e intercambios; opcional RPC a otro nodo (`GESTOR_SALAS_NODE`).

| Función | Qué hace y para qué sirve |
|---------|---------------------------|
| `normalizar_id_sala/1` | Unifica formato `S-1001` / `I-1001`. |
| `__local_gs_call__/1` | Uso interno para RPC remoto. |
| `listar_salas/0` | Ids de salas de batalla abiertas. |
| `crear_sala/2` | Crea sala de batalla y devuelve `room_id`. |
| `unirse_sala/3` | Une segundo jugador a la sala de batalla. |
| `iniciar_batalla/2` | Inicia el combate en esa sala. |
| `ataque/3` | Envía acción de ataque a la batalla correspondiente. |
| `cambiar/3` | Envía cambio de Pokémon. |
| `rendirse/2` | Rendición en la sala. |
| `obtener_ultimo_orden/1` | Delega en el `pid` de batalla. |
| `obtener_batalla_estado/1` | Estado de la batalla por `room_id`. |
| `crear_sala_intercambio/2` | Crea sala de intercambio. |
| `unirse_sala_intercambio/3` | Segundo jugador al intercambio. |
| `ofrecer_pokemon_intercambio/3` | Propone Pokémon a intercambiar. |
| `confirmar_intercambio/2` | Confirma; ejecuta si ambos confirmaron y hay ofertas. |
| `cancelar_intercambio/2` | Cancela la sala de intercambio. |
| `obtener_intercambio_estado/1` | Estado de la sala de intercambio. |

---

## `PokemonBattle.Intercambio` (GenServer por sala)

**Propósito:** máquina de estados del intercambio en tiempo real entre dos jugadores.

| Función | Qué hace y para qué sirve |
|---------|---------------------------|
| `unirse/3` | Entra el segundo jugador. |
| `ofrecer_pokemon/3` | Ofrece un id de Pokémon del inventario. |
| `confirmar_intercambio/2` | Marca confirmación; intercambia si ambos listos. |
| `cancelar_intercambio/2` | Cancela. |
| `obtener_estado/1` | Vista del estado de la sala. |

---

## `PokemonBattle.Servidor` (GenServer)

**Propósito:** interpretar strings de consola y llamar a gestores; mantiene sesión, sala de batalla e intercambio activos.

| Función | Qué hace y para qué sirve |
|---------|---------------------------|
| `start_link/1` | Arranca el GenServer `PokemonBattle.Servidor`. |
| `comando/1` | Parsea texto y devuelve `{:ok, msg}` o `{:error, msg}` en español. |

Los comandos de texto (`iniciar`, `perfil`, `crear_sala`, etc.) están descritos en el `README.md`.

---

## `PokemonBattle.Cluster`

**Propósito:** utilidades de red Erlang para demostración distribuida.

| Función | Qué hace y para qué sirve |
|---------|---------------------------|
| `conectar/1` | `Node.connect` a cada nodo de la lista. |
| `conectar_desde_env/0` | Lee `CLUSTER_NODES` y conecta. |
| `pick_node/0` | Elige nodo para batalla según env `BATTLE_NODE`. |
| `crear_sala_batalla_en_nodo/3` | RPC: crea sala en otro nodo BEAM. |

---

## Generar documentación HTML (opcional)

Desde la raíz del proyecto:

```bash
mix docs
```

(Requiere dependencia `ex_doc` en `mix.exs` si aún no está.)
