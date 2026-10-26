# Program the FPGA over JTAG (volatile).
$ErrorActionPreference = "Stop"
$quartus = "C:\intelFPGA_standard\lite\quartus\bin64"
$sof     = Join-Path $PSScriptRoot "..\quartus\output_files\de0_nano_sdram.sof"

& "$quartus\quartus_pgm.exe" -c "USB-Blaster" -m jtag -o "p;$sof"
if ($LASTEXITCODE -ne 0) { throw "Programming failed (exit $LASTEXITCODE)" }
