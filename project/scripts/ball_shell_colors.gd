# SPDX-License-Identifier: MIT
# Supplied ShellColors palette and shell/marking rules, applied to active mod art.
extends RefCounted
const PALETTES={"GREAT BALL":["3068d8","e84030"],"ULTRA BALL":["303038","f0c828"],"MASTER BALL":["7838a8","e860b0","e860b0"],"PARK BALL":["f0b028","48a048"],"FAST BALL":["f08828","f8d848"],"LEVEL BALL":["d83828","f8c838"],"LURE BALL":["2880c8","40b860","186028"],"HEAVY BALL":["8894a8","3860c8"],"LOVE BALL":["f070b0"],"FRIEND BALL":["40a848","d84030"],"MOON BALL":["384888","f0d040"],"DUSK BALL":["282828","40b048","78f060"],"QUICK BALL":["4078e0","f8d030"],"NET BALL":["18a8b0","202830"],"NEST BALL":["78b030","e0a838"],"HEAL BALL":["f890c8"],"DREAM BALL":["e078d0","9060c8"],"DIVE BALL":["2050c0","78c0f0","102060"],"TIMER BALL":["c8c8c8","d84030"]}
static func shell(c:Color)->bool:return c.a>0 and c.s>=0.25 and c.v>=0.15
static func lightness(c:Color)->float:return (maxf(c.r,maxf(c.g,c.b))+minf(c.r,minf(c.g,c.b)))*0.5
static func at_lightness(c:Color,target:float)->Color:
    var high=maxf(c.r,maxf(c.g,c.b));var low=minf(c.r,minf(c.g,c.b))
    var l=(high+low)*0.5;var d=high-low
    var saturation=0.0 if d==0 else d/(1-absf(2*l-1))
    var chroma=(1-absf(2*target-1))*saturation
    var hue=c.h*6;var x=chroma*(1-absf(fmod(hue,2)-1));var m=target-chroma/2
    var channels=[Vector3(chroma,x,0),Vector3(x,chroma,0),Vector3(0,chroma,x),Vector3(0,x,chroma),Vector3(x,0,chroma),Vector3(chroma,0,x)][mini(5,int(hue))]
    return Color(channels.x+m,channels.y+m,channels.z+m,c.a)
static func shade(c:Color,l:float,reference:float)->Color:
    var base=lightness(c)
    return at_lightness(c,base*l/reference if l<=reference and reference>0 else base+(1-base)*(l-reference)/maxf(0.000001,1-reference))
static func lab_f(t:float)->float:return pow(t,1.0/3) if t>0.008856 else 7.787*t+16.0/116
static func lab(c:Color)->Vector3:
    c=c.srgb_to_linear()
    var x=lab_f((0.4124*c.r+0.3576*c.g+0.1805*c.b)/0.95047)
    var y=lab_f(0.2126*c.r+0.7152*c.g+0.0722*c.b)
    var z=lab_f((0.0193*c.r+0.1192*c.g+0.9505*c.b)/1.08883)
    return Vector3(116*y-16,150*(x-y),60*(y-z))
static func contrast(c:Color,around:Array)->float:
    var score=INF
    for other in around:score=minf(score,lab(c).distance_to(lab(other)))
    return score
static func standout(c:Color,around:Array)->Color:
    var best=c;var score=contrast(c,around);var distance=INF
    if score>=27:return c
    for step in range(101):
        var candidate=at_lightness(c,step/100.0);var next=contrast(candidate,around)
        var delta=absf(step/100.0-lightness(c))
        if (next>=27 and (score<27 or delta<distance)) or (next<27 and score<27 and next>score):
            best=candidate;score=next;distance=delta
    return best
static func recolor(source:Image,ball:String)->Image:
    var result=source.duplicate()
    if not PALETTES.has(ball):return result
    var tones={};var count=0
    for y in range(source.get_height()):
        for x in range(source.get_width()):
            var c=source.get_pixel(x,y)
            if shell(c):c.a=1;tones[c]=int(tones.get(c,0))+1;count+=1
    if count==0:return result
    var reference:Color=tones.keys()[0];var darkest=reference
    for c in tones:
        if tones[c]>tones[reference]:reference=c
        if lightness(c)<lightness(darkest):darkest=c
    var palette=PALETTES[ball];var main=Color(palette[0]);var mid={};var marked=0;var stripes={}
    if palette.size()>1:
        for c in tones:
            if c!=darkest and lightness(c)<lightness(reference):mid[c]=true;marked+=tones[c]
        if marked==0 or marked>count*0.4:
            mid.clear()
            for x in range(source.get_width()):
                for y in range(source.get_height()-1,-1,-1):
                    var c=source.get_pixel(x,y)
                    if c.a==0:continue
                    c.a=1
                    if c!=reference:continue
                    var at=Vector2i(x,y)
                    if y+1<source.get_height():
                        var below=source.get_pixel(x,y+1)
                        if shell(below) and below!=reference:at.y+=1
                    stripes[at]=true
                    break
            if stripes.size()>count*0.4:stripes.clear()
    var accent=Color(palette[1]) if palette.size()>1 else main
    if not stripes.is_empty():
        if palette.size()>2:accent=Color(palette[2])
        else:
            var around=[]
            for at in stripes:
                for offset in [Vector2i.UP,Vector2i.DOWN]:
                    var next=at+offset
                    if next.y<0 or next.y>=source.get_height() or stripes.has(next):continue
                    var c=source.get_pixelv(next)
                    if shell(c):around.append(shade(main,lightness(c),lightness(reference)))
            accent=standout(accent,around)
    for y in range(source.get_height()):
        for x in range(source.get_width()):
            var c=source.get_pixel(x,y)
            if not shell(c):continue
            var alpha=c.a;c.a=1
            var next=accent if mid.has(c) or stripes.has(Vector2i(x,y)) else shade(main,lightness(c),lightness(reference))
            next.a=alpha
            result.set_pixel(x,y,next)
    return result
