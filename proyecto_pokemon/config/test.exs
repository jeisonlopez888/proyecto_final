import Config

import_config "config.exs"

# Datos aislados para ExUnit (no tocar `data/` de desarrollo).
root = Path.dirname(__DIR__)
config :proyecto_pokemon, :data_dir, Path.join(root, "data_test")
