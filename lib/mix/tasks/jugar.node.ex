defmodule Mix.Tasks.Jugar.Node do
  @moduledoc false

  @default_cookie "proyecto_pokemon"

  def sname_entrenador(slug) do
    host = Application.get_env(:proyecto_pokemon, :cluster_host, "127.0.0.1")
    "#{slug}@#{host}"
  end

  def run(sname, hints) when is_binary(sname) and is_list(hints) do
    Mix.Task.run("compile")

    cookie = System.get_env("ERL_COOKIE") || @default_cookie
    System.put_env("ERL_COOKIE", cookie)

    Mix.shell().info("=== Batallas Pokémon — #{sname} ===")
    Enum.each(hints, fn line -> Mix.shell().info(line) end)
    Mix.shell().info("")

    {exe, args} =
      case :os.type() do
        {:win32, _} -> {"iex.bat", ["--sname", sname, "-S", "mix"]}
        _ -> {"iex", ["--sname", sname, "-S", "mix"]}
      end

    env = [{"ERL_COOKIE", cookie}]

    case System.cmd(exe, args, into: IO.stream(:stdio, :line), env: env) do
      {_, 0} -> :ok
      _ -> System.halt(1)
    end
  end
end
