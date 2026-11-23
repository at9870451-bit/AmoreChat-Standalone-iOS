from PIL import Image, ImageDraw
from pathlib import Path
p=Path(__file__).resolve().parents[1]/'AmoreChat/Assets.xcassets/AppIcon.appiconset'
p.mkdir(parents=True,exist_ok=True)
im=Image.new('RGB',(1024,1024),'#3269DF')
d=ImageDraw.Draw(im)
d.rounded_rectangle((167,173,857,851),radius=244,fill='#FFFFFF')
d.polygon([(408,781),(363,946),(571,819)],fill='#FFFFFF')
d.ellipse((264,271,750,747),fill='#3269DF')
d.ellipse((360,472,411,523),fill='#FFFFFF')
d.ellipse((484,472,535,523),fill='#FFFFFF')
d.ellipse((608,472,659,523),fill='#FFFFFF')
im.save(p/'AppIcon.png')
(p/'Contents.json').write_text('{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}\n')
