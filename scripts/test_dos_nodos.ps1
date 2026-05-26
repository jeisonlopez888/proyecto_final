# Levanta ana_demo, ejecuta prueba desde luis_demo y muestra resultado.
$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)
$env:ERL_COOKIE = "proyecto_pokemon"

Write-Host "Iniciando nodo ana_demo@127.0.0.1 (ventana minimizada)..."
$ana = Start-Process cmd.exe -ArgumentList @(
  "/k",
  "cd /d $(Get-Location) && set ERL_COOKIE=proyecto_pokemon&& iex.bat --sname ana_demo@127.0.0.1 -S mix"
) -PassThru -WindowStyle Minimized

Start-Sleep -Seconds 18

Write-Host "Ejecutando prueba desde luis_demo@127.0.0.1..."
$out = @(
  'Code.eval_file("scripts/test_dos_nodos.exs")',
  "System.halt(0)"
) -join "; " | & iex.bat --sname luis_demo@127.0.0.1 -S mix 2>&1
$out | ForEach-Object { Write-Host $_ }

Write-Host ""
Write-Host "Cierra la ventana minimizada de ana_demo cuando termines (o mata el proceso cmd $($ana.Id))."

if ($LASTEXITCODE -ne 0) { exit 1 }
