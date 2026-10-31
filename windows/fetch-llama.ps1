# Downloads the llama.cpp server pinned in llama.json into Lingveil.App\llama\, once.
# The build copies that folder next to Lingveil.exe.
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$pin = Get-Content (Join-Path $here 'llama.json') -Raw | ConvertFrom-Json
$dest = Join-Path $here 'Lingveil.App\llama'
$stamp = Join-Path $dest '.tag'
if ((Test-Path $stamp) -and ((Get-Content $stamp) -eq $pin.tag)) { return }

$zip = Join-Path ([IO.Path]::GetTempPath()) "llama-$($pin.tag).zip"
Invoke-WebRequest $pin.url -OutFile $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne $pin.sha256) { Remove-Item $zip; throw "llama.cpp download hash mismatch: $hash" }

if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
New-Item -ItemType Directory $dest | Out-Null
Expand-Archive $zip -DestinationPath $dest
Remove-Item $zip
# Keep only what the server needs: the exe and its DLLs.
Get-ChildItem $dest -File | Where-Object { $_.Extension -ne '.dll' -and $_.Name -ne 'llama-server.exe' } | Remove-Item
'cli', 'bench', 'batched-bench', 'perplexity', 'quantize', 'completion' | ForEach-Object { Remove-Item (Join-Path $dest "llama-$_-impl.dll") -ErrorAction SilentlyContinue }
Set-Content $stamp $pin.tag
Write-Host "llama.cpp $($pin.tag) ready in $dest"
