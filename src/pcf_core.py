#!/usr/bin/env python3
# pcf_core.py <in.pcf> <out.pcf>: the constraints of the Mini / Mini G without those of the FT mode of HDMI, for the
# trce of `make <board>-coremode`. In the mode of the core the pixel clock is clk_vid (BUFGMUX of pll2, ft_sel 0); in
# the full analysis its flip-flops are also on DCM_CLKGEN (the PERIODs ngdbuild derives from clk_8) and TS_VID_TO_PIX
# bounds the paths from clk_vid as asynchronous ones. Without them, the paths clk_vid -> pixel clock get the setup and
# hold of TS_pll2_clk_0_, the clock of clk_vid. (After pcf_core.py of karabas-go-core-tsconf.)
import re
import sys

DROP = re.compile(r'^(TS_VID_TO_PIX|TS_hdmi_top_hdmi_pll_(clkgen|clkfx|clkfx180)_0)$')
NEED = {'TS_VID_TO_PIX', 'TS_hdmi_top_hdmi_pll_clkgen_0'}

text = open(sys.argv[1]).read()
out, dropped = [], []
for m in re.finditer(r'(?ms)^(\S+) = (?:PERIOD|MAXDELAY).*?;\n|^.*?\n', text):
    name = m.group(0).split(' ', 1)[0]
    if m.group(1) and DROP.match(name):
        dropped.append(name)
        continue
    out.append(m.group(0))
if not NEED <= set(dropped):
    sys.exit('pcf_core.py: ' + ' / '.join(sorted(NEED - set(dropped))) + ' not found in ' + sys.argv[1])
open(sys.argv[2], 'w').write(''.join(out))
print('pcf_core.py: without ' + ' '.join(dropped))
