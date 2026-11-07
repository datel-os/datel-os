#
# Creality K1 (Ingenic X2000-V12): U-Boot proper runs from DDR at 0x80100000
# (the SPL loads it there from eMMC sector 82).
#
ifndef TEXT_BASE
TEXT_BASE = 0x80100000
endif
