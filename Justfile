# tape/DIVERSE.GAM is a tape byte copy with a 5-byte prefix (E6 AA AA BB BB)
# where AAAA=start address, BBBB=end address, and a 3-byte trailer (E6 XX YY)
# with 2 bytes pre-trailer (00 00) where XXYY=checksum.

ci: build test

build:
    bunx asm8080 --split -l --format gam --trailer-padding diverse.asm

test:
    xxd -g 1 tape/DIVERSE.GAM >DIVERSE-tape.hex
    xxd -g 1 diverse.gam >diverse.hex
    diff DIVERSE-tape.hex diverse.hex
