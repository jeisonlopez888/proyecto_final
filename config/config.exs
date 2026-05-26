import Config

# Directorio raíz del proyecto (carpeta que contiene /config)
root_dir = Path.dirname(__DIR__)

config :proyecto_pokemon,
  data_dir: Path.join(root_dir, "data"),
  cluster_cookie: "proyecto_pokemon",
  # En Windows/OTP 28 "localhost" provoca: Hostname localhost is illegal
  cluster_host: "127.0.0.1"
