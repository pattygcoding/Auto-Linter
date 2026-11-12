$ErrorActionPreference = "Stop"
Push-Location (Join-Path $PSScriptRoot "..")

try {
    if (-not (Get-Command zig -ErrorAction SilentlyContinue)) {
        throw "zig was not found. Install Zig 0.16 or newer from https://ziglang.org/download/ first."
    }

    zig build -Doptimize=ReleaseSmall
    if ($LASTEXITCODE -ne 0) {
        throw "WASM build failed."
    }

    Copy-Item "zig-out\bin\formatter.wasm" "formatter.wasm" -Force
    $size = (Get-Item "formatter.wasm").Length
    Write-Output "Built formatter.wasm ($size bytes) with Zig. formatter.js is committed, so nothing else is generated."
} finally {
    Pop-Location
}