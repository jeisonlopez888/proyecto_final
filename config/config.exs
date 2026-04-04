import Config

# Directorio raíz del proyecto (carpeta que contiene /config)
root_dir = Path.dirname(__DIR__)

config :proyecto_pokemon,
  data_dir: Path.join(root_dir, "data")
