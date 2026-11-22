# Run from an ADMINISTRATOR PowerShell:
#   powershell -ExecutionPolicy Bypass -File scripts\trust-ca.ps1
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$out  = Join-Path $repo "artifacts\fray-ca.cer"

Push-Location (Join-Path $repo "vagrant")
try {
    $raw = vagrant ssh -c "openssl x509 -in /usr/local/share/ca-certificates/fray-ca.crt -outform DER | base64 -w0"
} finally {
    Pop-Location
}

# Keep only the base64 line, ignoring any other messages Vagrant prints
$b64 = ($raw | Where-Object { $_ -match '^[A-Za-z0-9+/=]{100,}$' }) -join ''
if (-not $b64) { throw "No certificate received from the VM. Is it running and provisioned (40-tls)?" }
[IO.File]::WriteAllBytes($out, [Convert]::FromBase64String($b64))

certutil -dump $out | Select-String "Subject:|Not After"
certutil -addstore -f Root $out