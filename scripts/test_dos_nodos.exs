# Prueba automatizada: nodo luis_demo conecta a ana_demo y usa GestorSalas por RPC.
# Ejecutar DESPUÉS de levantar ana_demo en otra ventana, o vía test_dos_nodos.ps1

target = :"ana_demo@127.0.0.1"

IO.puts("=== PRUEBA 2 NODOS ===")
IO.puts("Nodo actual: #{inspect(Node.self())}")
IO.puts("Ping #{inspect(target)}: #{inspect(:net_adm.ping(target))}")

connected =
  case Node.connect(target) do
    true -> true
    false -> :net_adm.ping(target) == :pong
  end

IO.puts("Conectado: #{connected}")
IO.puts("Node.list: #{inspect(Node.list())}")

if connected do
  System.put_env("GESTOR_SALAS_NODE", "ana_demo@127.0.0.1")

  case PokemonBattle.GestorSalas.crear_sala("ana_user", []) do
    {:ok, room_id} ->
      IO.puts("RPC crear_sala OK: #{room_id}")

      case PokemonBattle.GestorSalas.unirse_sala(room_id, "luis_user", nil) do
        {:ok, msg} ->
          IO.puts("RPC unirse OK: #{inspect(msg)}")
          IO.puts("RESULTADO: DISTRIBUCION OK")

        other ->
          IO.puts("RPC unirse fallo: #{inspect(other)}")
          System.halt(1)
      end

    other ->
      IO.puts("RPC crear_sala fallo: #{inspect(other)}")
      System.halt(1)
  end
else
  IO.puts("RESULTADO: FALLO - no hay conexion con ana_demo@127.0.0.1")
  System.halt(1)
end
