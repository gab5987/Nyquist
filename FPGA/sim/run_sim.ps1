# Compile and run the testbench in Questa FSE (batch mode).
$ErrorActionPreference = "Stop"
$questa = "C:\intelFPGA_standard\lite\questa_fse\win64"
$simdir = $PSScriptRoot
$rtl    = Join-Path $simdir "..\rtl"
$work   = Join-Path $simdir "work"

Push-Location $simdir
try {
    if (-not (Test-Path $work)) { & "$questa\vlib.exe" work }
    & "$questa\vlog.exe" -sv -quiet `
        "$rtl\sdram_ctrl.sv" "$rtl\sdram_tester.sv" `
        "$simdir\sdram_model.sv" "$simdir\tb_sdram.sv"
    if ($LASTEXITCODE -ne 0) { throw "vlog failed" }
    & "$questa\vsim.exe" -c -quiet work.tb_sdram -do "run -all; quit -f"
    if ($LASTEXITCODE -ne 0) { throw "vsim failed" }
} finally {
    Pop-Location
}
