import nitf_lib

def ResExtHeader =
  block
    Match "RE"
    resid = Many 25 BCSA
    resver = PosNumber 2

    common = CommonSubheader

    -- TODO: implement validation in note on p125

    resshl = UnsignedNum 4 as? uint 64
    resshf = Many resshl BCSA

    Many Byte

    -- TODO: refactor above fields into lib
