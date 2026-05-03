## Clock
set_property -dict { PACKAGE_PIN E3 IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -name sys_clk -period 10.0 [get_ports clk]

## Reset button (optional but recommended)
set_property -dict { PACKAGE_PIN D9 IOSTANDARD LVCMOS33 } [get_ports rst_btn]

## 7-Segment via PMOD

# A
set_property PACKAGE_PIN A18 [get_ports seg[0]]

# B
set_property PACKAGE_PIN A11 [get_ports seg[1]]

# C
set_property PACKAGE_PIN D12 [get_ports seg[2]]

# D
set_property PACKAGE_PIN B18 [get_ports seg[3]]

# E
set_property PACKAGE_PIN B11 [get_ports seg[4]]

# F
set_property PACKAGE_PIN G13 [get_ports seg[5]]

# G
set_property PACKAGE_PIN D13 [get_ports seg[6]]

set_property IOSTANDARD LVCMOS33 [get_ports {seg[*]}]