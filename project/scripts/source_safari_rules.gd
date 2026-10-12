extends RefCounted
# Literal integer rules from DrawBattleMenuSafariZone, ThrowBait/ThrowRock,
# PrintAngryEating and ChanceToRun (0.8.11). Independent of normal ball rules.
static func begin(base_rate: int) -> Dictionary:
    return {"base_rate":base_rate,"rate":base_rate,"angry":0,"eating":0}
static func bait(state: Dictionary, duration: int) -> void:
    state.rate=int(int(state.rate)/2)
    state.eating=mini(255,int(state.eating)+duration)
    state.angry=0
static func rock(state: Dictionary, duration: int) -> void:
    state.rate=mini(255,int(state.rate)*2)
    state.angry=mini(255,int(state.angry)+duration)
    state.eating=0
static func mood(state: Dictionary) -> String:
    if int(state.angry)>0:
        state.angry-=1
        if int(state.angry)<=0:state.rate=state.base_rate
        return "angry"
    if int(state.eating)>0:
        state.eating-=1
        return "eating"
    return ""
static func catch_outcome(rate: int, adrenaline: int, roll: int) -> int:
    var f:=int(rate*255*4/(100*15))
    if f+mini(25,adrenaline)*10>=roll:return -1
    var d:=int(rate*100/150)
    if d>=256:return 3
    var x:=int(d*f/255)
    return 0 if x<10 else 1 if x<30 else 2 if x<70 else 3
static func flee_threshold(speed: int, state: Dictionary) -> int:
    var x: int=(speed%256)*2
    if x>255:return 256
    if int(state.angry)>0:return mini(255,x*2)
    if int(state.eating)>0:return int(x/4)
    return x
