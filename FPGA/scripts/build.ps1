# Full Quartus compile (synthesis, fitter, STA, assembler).
$ErrorActionPreference = "Stop"
$quartus = "C:\intelFPGA_standard\lite\quartus\bin64"
$proj    = Join-Path $PSScriptRoot "..\quartus"

Push-Location $proj
try {
    & "$quartus\quartus_sh.exe" --flow compile de0_nano_sdram
    if ($LASTEXITCODE -ne 0) { throw "Compile failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}
