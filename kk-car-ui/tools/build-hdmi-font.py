#!/usr/bin/env python3
"""Build the local bitmap subset from OFL Noto Sans CJK SC Regular.
Usage: python3 build-hdmi-font.py SOURCE_FONT OUTPUT_JSON
Requires Pillow on the development computer, never on the router.
"""
import json,math,sys
from pathlib import Path
from PIL import Image,ImageFont,ImageDraw
source=Path(__file__).resolve().parents[1]/'root/etc/kk-car/hdmi.uc'
characters=set(chr(x) for x in range(32,127))|{x for x in source.read_text() if ord(x)>127}|set('中国电信移动联通未知')
glyphs={}
for size in (18,20,22,24,40):
 font=ImageFont.truetype(sys.argv[1],size)
 selected=characters if size!=40 else {x for x in characters if ord(x)<127}|set('未知')
 entries={}
 for ch in sorted(selected):
  width=max(1,math.ceil(font.getlength(ch)))
  im=Image.new('L',(width,size));ImageDraw.Draw(im).text((0,int(size*.84)),ch,font=font,fill=255,anchor='ls')
  entries[ch]={'w':width,'rows':[''.join(format(im.getpixel((x,y))//17,'x') for x in range(width)) for y in range(size)]}
 glyphs[str(size)]=entries
Path(sys.argv[2]).write_text(json.dumps({'name':'KK-Car display bitmap subset','source':'Noto Sans CJK SC Regular','license':'OFL-1.1; see hdmi-font.LICENSE','glyphs':glyphs},ensure_ascii=False,separators=(',',':')))
print('Generated',len(characters),'characters;',Path(sys.argv[2]).stat().st_size,'bytes')
