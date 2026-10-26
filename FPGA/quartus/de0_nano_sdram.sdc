# Timing constraints: DE0-Nano + IS42S16160G-7 at 100 MHz
create_clock -name clk_50 -period 20.000 [get_ports {CLOCK_50}]

derive_pll_clocks
derive_clock_uncertainty

set clk_sys   [get_clocks {u_pll|altpll_component|auto_generated|pll1|clk[0]}]
set clk_sdram [get_pins   {u_pll|altpll_component|auto_generated|pll1|clk[1]}]

create_generated_clock -name sdram_clk_ext -source $clk_sdram [get_ports {DRAM_CLK}]

set sdram_outputs [get_ports {DRAM_ADDR[*] DRAM_BA[*] DRAM_CAS_N DRAM_CKE DRAM_CS_N \
                              DRAM_DQ[*] DRAM_DQM[*] DRAM_RAS_N DRAM_WE_N}]
set sdram_inputs  [get_ports {DRAM_DQ[*]}]

# SDRAM inputs: tDS = 1.5 ns, tDH = 0.8 ns, plus trace margin
set_output_delay -clock sdram_clk_ext -max  2.0 $sdram_outputs
set_output_delay -clock sdram_clk_ext -min -1.0 $sdram_outputs

# SDRAM outputs: tAC = 5.4 ns (CL3), tOH = 2.7 ns
set_input_delay  -clock sdram_clk_ext -max  6.0 $sdram_inputs
set_input_delay  -clock sdram_clk_ext -min  2.5 $sdram_inputs

# Read data is captured on the 2nd internal edge after the SDRAM edge
set_multicycle_path -setup -end 2 -from [get_clocks sdram_clk_ext] -to $clk_sys

set_false_path -from [get_ports {KEY[*]}]
set_false_path -to   [get_ports {LED[*]}]
