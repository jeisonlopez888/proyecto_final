# Proyecto final — Batallas Pokémon (Elixir/OTP)

## ¿Qué es este proyecto?

Es una **plataforma de batallas Pokémon por turnos** orientada a consola (`iex`), construida con **Elixir** y **OTP**: procesos `GenServer`, `DynamicSupervisor`, persistencia en **JSON** y soporte para **varios nodos BEAM** (cluster).

Cumple el alcance típico de un proyecto académico de este tipo:

| Área | Qué incluye |
|------|-------------|
| **Cuenta** | Registro e inicio de sesión (`iniciar` crea cuenta si no existe), cierre (`salir`), perfil, monedas y estadísticas persistentes. |
| **Colección** | Sobres con 3 Pokémon, rareza según tipo de sobre, 4 movimientos por Pokémon (reglas de tipos), economía (monedas, tienda). |
| **Equipos** | Equipos guardados (1–3 Pokémon), activar equipo para batalla, listar, quitar/agregar Pokémon del equipo. |
| **Combate** | Salas 1v1, turnos simultáneos (dos acciones por ronda), orden por velocidad, daño con tipos, STAB y defensa con uno o dos tipos. |
| **Intercambio** | Sala en tiempo real entre dos entrenadores conectados (oferta, confirmación, cancelación). |
| **Concurrencia** | Cada batalla e intercambio vive en su propio `GenServer` bajo supervisión. |
| **Distribución** | Posible ejecutar en 2+ nodos con `Node.connect/1` y variable `GESTOR_SALAS_NODE` (ver más abajo). |
| **Datos** | `data/trainers.json`, `pokemon.json`, `moves.json`, `tienda.json`, `battles.log`. |

Los detalles de fórmulas, tablas de tipos y reglas de sobres están implementados en `lib/pokemon_battle/` (por ejemplo `motor_combate.ex`, `sistema_sobres.ex`, `batalla.ex`).

**Referencia de API (qué hace cada módulo y función pública):** consulta [`DOCUMENTACION.md`](DOCUMENTACION.md). En el código, los `@moduledoc` y `@doc` de los `.ex` repiten o amplían lo mismo en español.

---

## Requisitos

- Elixir `~> 1.19`
- Dependencia: `jason`

Instalación y compilación (en la carpeta donde está `mix.exs`):

```bash
mix deps.get
mix compile
```

---

## Menú interactivo (recomendado para jugar)

### Cómo iniciarlo (Windows)

1. Abre **PowerShell** o **cmd**.
2. Ve a la carpeta del proyecto (donde está `mix.exs`):

   ```powershell
   Set-Location c:\Users\User\proyecto_final
   ```

3. (Solo la primera vez o si faltan librerías) `mix deps.get`
4. Ejecuta el juego con menú:

   ```powershell
   mix jugar
   ```

5. En pantalla verás números: **1** iniciar sesión, **2** crear entrenador (primera vez), **0** salir.  
   Tras entrar, el **menú principal** lista todo: perfil y récord, inventario, tienda/sobres, equipos, batalla (crear sala, **ver salas activas**, unirse, pelear), intercambio y clasificación global. Tras cada acción, pulsa **Enter** para volver al menú.

**Alternativa** (mismo menú desde Elixir interactivo):

```powershell
iex.bat -S mix
```

```elixir
PokemonBattle.MenuJuego.iniciar()
```

Por debajo el menú usa `PokemonBattle.Servidor` (misma lógica que los comandos de texto).

---

## Cómo abrir IEx (importante en Windows / PowerShell)

En **PowerShell**, `iex` es el alias de `Invoke-Expression`, **no** es Elixir. Usa:

```powershell
iex.bat -S mix
```

O abre **cmd** y ahí sí:

```cmd
iex -S mix
```

---

## Cómo invocar comandos

Todo pasa por el intérprete de consola:

```elixir
PokemonBattle.Servidor.comando("texto del comando")
```

La respuesta suele ser `{:ok, "mensaje"}` o `{:error, "mensaje"}`.

### Modo principiante (recomendado para sustentar)

Si quieres mostrar una version mas simple (sin memorizar todos los comandos de texto),
usa el modulo `PokemonBattle.ComandosBasicos`:

```elixir
PokemonBattle.ComandosBasicos.iniciar("ana", "1234")
PokemonBattle.ComandosBasicos.perfil()
PokemonBattle.ComandosBasicos.inventario()
PokemonBattle.ComandosBasicos.tienda()
PokemonBattle.ComandosBasicos.ayuda()
```

Esta capa usa solo conceptos basicos (strings, listas, tuplas y Enum) pero conserva
la arquitectura recomendada por debajo (`Servidor`, `GenServer`, `Supervisor`, archivos JSON).

---

## Limitación del `Servidor`: una sesión a la vez

`PokemonBattle.Servidor` guarda **un solo usuario logueado**. Si haces `iniciar ana` y luego `iniciar luis`, la sesión activa pasa a ser **Luis**; los comandos `ataque`, `cambiar`, etc. se aplican como **Luis**.

Para **dos jugadores en el mismo `iex`** sin cambiar de sesión todo el rato, puedes enviar acciones por nombre con el gestor:

```elixir
PokemonBattle.GestorSalas.ataque("S-1001", "ana", "impactrueno")
PokemonBattle.GestorSalas.ataque("S-1001", "luis", "pistola_agua")
```

Los **id de movimiento** deben coincidir **exactamente** con los que ves en `inventario` para cada Pokémon (no inventes nombres: si sale `rayo`, usa `rayo`).

---

## Dos ventanas `iex` = batalla online entre terminales

Al **iniciar sesión** (o crear entrenador), la app configura automáticamente:

- Nodo BEAM con el nombre del usuario (`ana` → `ana@127.0.0.1`, `luis` → `luis@127.0.0.1`; en Windows no uses `localhost`).
- Cookie de cluster (`proyecto_pokemon`, configurable en `config/config.exs`).
- Conexión con otros entrenadores registrados (`data/cluster_nodes.json`).
- Búsqueda de salas en todos los nodos conectados (no hace falta `GESTOR_SALAS_NODE` a mano).

### Arranque (recomendado)

En **cada** terminal:

```powershell
cd ruta\al\proyecto
iex.bat -S mix
```

```elixir
PokemonBattle.MenuJuego.iniciar()
```

| Terminal | Login | Qué verás tras entrar |
|----------|-------|------------------------|
| 1 | **ana** | `Nodo de red: :'ana@127.0.0.1' ...` |
| 2 | **luis** | `Nodo de red: :'luis@127.0.0.1' ... Conectado a: ana@127.0.0.1` |

Luego: Terminal 1 → menú **5** → **1** (crear sala `S-xxxx`). Terminal 2 → menú **5** → **3** (unirse al mismo código).

**Importante:** un IEx = un entrenador. Si ya entraste como **ana** en una ventana, no puedes cambiar a **luis** en la misma; abre otra terminal para el segundo jugador.

Atajos con nombre de nodo ya fijado: `mix jugar.ana` / `mix jugar.luis` (opcional).

### Errores frecuentes

| Síntoma | Qué hacer |
|---------|-----------|
| No aparece línea `Nodo de red:` | Vuelve a iniciar sesión; comprueba que el usuario solo tenga letras, números o `_` |
| `Conectado a:` vacío en la 2.ª terminal | Entra primero en Terminal 1 como **ana**, luego en Terminal 2 como **luis** |
| Sala no existe | Mismo código `S-xxxx`; ambos con sesión iniciada y terminales abiertas |
| Mismo entrenador en dos ventanas | Usa usuarios distintos (ana / luis) |

**No** escribas comandos Elixir en el prompt `PS C:\...>`; solo dentro de `iex(...)>`.

### Prueba automática del cluster

```powershell
powershell -ExecutionPolicy Bypass -File scripts\test_dos_nodos.ps1
```

*(Opcional: `CLUSTER_NODES` o `GESTOR_SALAS_NODE` siguen funcionando para forzar un gestor remoto.)*

---

## Lista de comandos del `Servidor`

| Comando | Descripción |
|---------|-------------|
| `iniciar <usuario> <clave>` | Inicia sesión; si no existe, registra (1 sobre básico gratis en cola). |
| `salir` | Cierra sesión. |
| `perfil` | Monedas, sobres pendientes, tamaño de inventario, victorias. |
| `inventario` | Lista Pokémon con stats y movimientos (usa los **nombres exactos** de movimientos en batalla). |
| `clasificacion` | Ranking por victorias y monedas acumuladas históricas. |
| `tienda` | Tipos de sobre, precio y probabilidades de rareza. |
| `comprar_sobre basico` | Compra sobre básico (clave interna `sobre_basico`). |
| `comprar_sobre avanzado` | Compra sobre avanzado (`sobre_avanzado`). |
| `abrir_sobre ultimo` | Abre el siguiente sobre de la cola (FIFO). |
| `crear_sala` | Crea sala de batalla; opcional: `crear_sala tiempo_turno=20`. |
| `listar_salas` | Lista ids de salas abiertas en **este** nodo (o en el nodo del gestor si usas RPC). |
| `unirse_sala <id>` | Ej.: `unirse_sala S-1001` (también acepta `s-1001`). |
| `iniciar_batalla <id>` | Comienza el combate si hay 2 jugadores con equipo válido. |
| `estado_batalla` | Resumen de la sala guardada en la sesión. |
| `ataque <id_movimiento>` | Envía ataque del **usuario logueado** (debe ser movimiento del Pokémon activo). |
| `cambiar <id_pokemon>` | Cambia al Pokémon de equipo por id numérico de instancia. |
| `rendirse` | Rendición en la sala activa de la sesión. |
| `crear_equipo <nombre> <ids>` | 1–3 ids separados por comas: `crear_equipo rapido 12,34,56`. |
| `usar_equipo <nombre>` | Marca ese equipo como activo para la próxima batalla. |
| `listar_equipos` | Equipos guardados y Pokémon. |
| `quitar_pokemon_equipo <nombre> <id>` | Quita un Pokémon del equipo (no puede quedar vacío). |
| `agregar_pokemon_equipo <nombre> <id>` | Añade si el equipo tiene menos de 3. |
| `crear_sala_intercambio` | Crea sala de intercambio; guarda el código (ej. `I-1001`). |
| `unirse_sala_intercambio <codigo>` | El otro jugador entra. |
| `ofrecer_pokemon <id>` | Propone Pokémon del inventario. |
| `confirmar_intercambio` | Ambos deben confirmar para ejecutar. |
| `cancelar_intercambio` | Cancela la sala. |

---

## Paso a paso: un jugador (cuenta, sobres, equipo)

1. Arranca `iex.bat -S mix`.
2. Registro / login y sobre inicial:
   ```elixir
   PokemonBattle.Servidor.comando("iniciar ana 1234")
   PokemonBattle.Servidor.comando("abrir_sobre ultimo")
   ```
3. Ver Pokémon y movimientos:
   ```elixir
   PokemonBattle.Servidor.comando("inventario")
   ```
4. Crear y activar equipo (sustituye IDs por los de tu inventario):
   ```elixir
   PokemonBattle.Servidor.comando("crear_equipo equipo1 101,102")
   PokemonBattle.Servidor.comando("usar_equipo equipo1")
   ```
5. Tienda (opcional):
   ```elixir
   PokemonBattle.Servidor.comando("tienda")
   PokemonBattle.Servidor.comando("comprar_sobre basico")
   PokemonBattle.Servidor.comando("abrir_sobre ultimo")
   ```

---

## Paso a paso: batalla 1v1 (un solo `iex`)

**Jugador A (Ana):**

1. `iniciar ana 1234`
2. `usar_equipo equipo1` (u otro flujo con inventario previo)
3. `crear_sala` → anota el id (ej. `S-1001`)

**Jugador B (Luis):**

4. `iniciar luis 1234`
5. `usar_equipo equipo2`
6. `unirse_sala S-1001`

**Inicio del combate (cualquiera de los dos, con sesión coherente o usando el gestor):**

7. `iniciar_batalla S-1001`

**Cada turno (dos acciones por ronda — simultáneas):**

- Opción A — alternar sesión:
  1. `iniciar ana 1234` → `ataque <mov_de_ana>` (exactamente como en inventario del Pokémon activo de Ana)
  2. `iniciar luis 1234` → `ataque <mov_de_luis>`
- Opción B — sin cambiar sesión:
  ```elixir
  PokemonBattle.GestorSalas.ataque("S-1001", "ana", "impactrueno")
  PokemonBattle.GestorSalas.ataque("S-1001", "luis", "pistola_agua")
  ```

**Cambiar Pokémon activo** (misma lógica de sesión o con `GestorSalas.cambiar("S-1001", "ana", id_instancia)`).

**Rendirse** (con el usuario correspondiente en sesión o vía gestor si añades llamada directa; en CLI habitual):

```elixir
PokemonBattle.Servidor.comando("iniciar ana 1234")  # quien se rinde
PokemonBattle.Servidor.comando("rendirse")
```

Al terminar se actualizan monedas (victoria / participación), victorias y se escribe en `data/battles.log`.

---

## Paso a paso: intercambio

**Ana:**

```elixir
PokemonBattle.Servidor.comando("iniciar ana 1234")
PokemonBattle.Servidor.comando("crear_sala_intercambio")
```

Copia el código (ej. `I-1001`).

**Luis** (misma máquina = mismo nodo, o configuración cluster como en batallas):

```elixir
PokemonBattle.Servidor.comando("iniciar luis 1234")
PokemonBattle.Servidor.comando("unirse_sala_intercambio I-1001")
```

**Ambos** (en cualquier orden hasta confirmar):

```elixir
PokemonBattle.Servidor.comando("ofrecer_pokemon 42")
PokemonBattle.Servidor.comando("confirmar_intercambio")
```

Cuando los dos confirman, se intercambian los Pokémon entre inventarios. El campo **`dueño_original`** del Pokémon **no cambia** (sigue siendo quien lo obtuvo del sobre).

---

## Archivos de datos

| Archivo | Contenido |
|---------|-----------|
| `data/trainers.json` | Usuarios, hash de clave, monedas, cola de sobres, inventario, equipos, victorias… |
| `data/pokemon.json` | Catálogo de especies e instancias de Pokémon. |
| `data/moves.json` | Movimientos por tipo (ids usados en batalla). |
| `data/tienda.json` | Sobres básico/avanzado: precio y % de rareza. |
| `data/battles.log` | Líneas de texto de eventos de batalla/intercambio. |

El directorio base se configura en `config/config.exs` (`:data_dir`).

---

## Tests y verificación de requisitos

Comando estándar (en PowerShell, usa `;` entre órdenes si hace falta):

```powershell
Set-Location ruta\al\proyecto
mix test
# equivalente:
mix proyecto.verify
```

Ambos ejecutan la misma suite ExUnit y sirven como verificación automática alineada con los requisitos de la tabla siguiente.

| Requisito (resumen) | Cómo se verifica en código |
|---------------------|----------------------------|
| 1. Persistencia JSON | `test/pokemon_battle/persistencia_test.exs` (y flujos que escriben en `data_test/`) |
| 2. Varias batallas en paralelo | `test/pokemon_battle/batalla_test.exs` — *“requisito: varias batallas en paralelo”* |
| 3. Motor de combate (tipos, STAB, fórmula) | `test/pokemon_battle/motor_combate_test.exs` |
| 4. Progresión (sobres, equipos, monedas) | `test/pokemon_battle/sobres_test.exs`, `batalla_test.exs` (economía al rendirse) |
| 5. Intercambio en sala | `test/pokemon_battle/intercambio_test.exs` |
| 6. Consola (`Servidor`) | `test/pokemon_battle/servidor_test.exs` |
| 7. Distribución (2 nodos) | **Manual**: sección *Dos ventanas `iex`* + `GESTOR_SALAS_NODE` (no automatizable en ExUnit sin cluster dedicado) |

Los tests usan el directorio `data_test/` (ver `config/test.exs`), no tu carpeta `data/` de desarrollo.

---

## Resumen rápido: qué “pide” el proyecto en la práctica

1. **Persistencia** real en JSON.  
2. **Varias batallas** en paralelo (varias salas).  
3. **Motor de combate** con tipos y STAB.  
4. **Progresión**: sobres → Pokémon → equipos → monedas por batalla → tienda.  
5. **Intercambio** en sala dedicada.  
6. **Demostración distribuida**: dos nodos con la misma app, `Node.connect` y `GESTOR_SALAS_NODE` para compartir salas entre consolas.

Si algo falla al unirse a una sala entre dos ventanas, revisa la sección **Dos ventanas iex** arriba: sin nodos conectados, la sala “no existe” en el segundo proceso.
