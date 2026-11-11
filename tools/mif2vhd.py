#!/usr/bin/env python3
"""Convert an Altera MIF (WIDTH=8) to a VHDL ROM entity for ISE/XST.

Usage: mif2vhd.py input.mif entity_name addr_width output.vhd
"""
import re
import sys


def parse_mif(path):
    text = open(path, encoding="utf-8", errors="ignore").read()
    width = int(re.search(r"WIDTH\s*=\s*(\d+)", text, re.I).group(1))
    depth = int(re.search(r"DEPTH\s*=\s*(\d+)", text, re.I).group(1))
    data_radix = re.search(r"DATA_RADIX\s*=\s*(\w+)", text, re.I)
    radix = (data_radix.group(1) if data_radix else "HEX").upper()
    mem = [0] * depth
    body = text[text.upper().find("CONTENT") :]
    for m in re.finditer(r"([0-9A-Fa-f]+)\s*:\s*([0-9A-Fa-f\s]+?)\s*;", body):
        addr = int(m.group(1), 16)
        values = m.group(2).split()
        for i, v in enumerate(values):
            if addr + i < depth:
                mem[addr + i] = int(v, 16 if radix == "HEX" else 2)
    return mem, depth, width


def main():
    src, ent, aw, dst = sys.argv[1:5]
    mem, depth, width = parse_mif(src)
    if width != 8:
        raise SystemExit("only 8-bit MIF supported")
    if depth > (1 << int(aw)):
        raise SystemExit("depth does not fit addr width")
    mem += [0] * ((1 << int(aw)) - len(mem))
    with open(dst, "w") as f:
        f.write("library IEEE;\nuse IEEE.STD_LOGIC_1164.ALL;\nuse IEEE.numeric_std.ALL;\n\n")
        f.write("entity %s is\n\tport (\n\t\tclk  : in  std_logic;\n" % ent)
        f.write("\t\taddr : in  unsigned(%d downto 0);\n" % (int(aw) - 1))
        f.write("\t\tdo   : out std_logic_vector(7 downto 0)\n\t);\nend entity;\n\n")
        f.write("architecture rtl of %s is\n" % ent)
        f.write("\ttype romDef is array(0 to %d) of std_logic_vector(7 downto 0);\n" % ((1 << int(aw)) - 1))
        f.write("\tconstant romData : romDef := (\n")
        for i in range(0, len(mem), 16):
            chunk = mem[i : i + 16]
            f.write("\t\t" + ", ".join('X"%02X"' % b for b in chunk))
            f.write(",\n" if i + 16 < len(mem) else "\n")
        f.write("\t);\nbegin\n")
        f.write("\tprocess(clk)\n\tbegin\n\t\tif rising_edge(clk) then\n")
        f.write("\t\t\tdo <= romData(to_integer(addr));\n")
        f.write("\t\tend if;\n\tend process;\nend architecture;\n")


if __name__ == "__main__":
    main()
