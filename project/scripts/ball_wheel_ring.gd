# SPDX-License-Identifier: MIT
# Godot port of the supplied BallRing.java. Input timing uses wall time;
# game speed changes animation, never the tap/hold threshold.
extends RefCounted
const FIELD = 0
const PARTY = 1
const BALLS = 2
const TAP_MILLIS = 250
const OPEN_GRACE_MILLIS = 1500
const TAP_GRACE_MILLIS = 400
var lt = false
var rt = false
var lt_live = false
var rt_live = false
var rt_tap = false
var lt_at = 0
var rt_at = 0
var tap_until = 0
var opened = false
var kind = FIELD

func update(left: bool, right: bool, now: int, idle: bool, available: Array, can_tap: bool) -> Array:
    var events = []
    var ld = not lt and left
    var lu = lt and not left
    var rd = not rt and right
    var ru = rt and not right
    lt = left
    rt = right
    if opened:
        for direction in ([1] if rd else []) + ([-1] if ld else []):
            for distance in range(1,3):
                var next = posmod(kind + direction * distance,3)
                if available[next]:
                    kind = next
                    events.append(["SWITCH",kind])
                    break
        if not lt and not rt:
            events.append(["CLOSE",kind])
            opened = false
    else:
        if ld:
            lt_live = true
            lt_at = now
            rt_tap = false
        if rd:
            rt_live = true
            rt_at = now
            rt_tap = not lt_live
        if lu: lt_live = false
        if ru and rt_live:
            rt_live = false
            if rt_tap and (now-rt_at<TAP_MILLIS or (not available[BALLS] and not lt_live)):
                tap_until = now+TAP_GRACE_MILLIS
            rt_tap = false
        elif ru: rt_tap = false
        var want = -1
        if lt_live and rt_live:
            if now-maxi(lt_at,rt_at)<=OPEN_GRACE_MILLIS:
                want = PARTY if available[PARTY] else FIELD if available[FIELD] else -1
        elif lt_live:
            if now-lt_at<=OPEN_GRACE_MILLIS: want = FIELD if available[FIELD] else -1
        elif rt_live:
            if now-rt_at>=TAP_MILLIS and now-rt_at<=TAP_MILLIS+OPEN_GRACE_MILLIS:
                want = BALLS if available[BALLS] else -1
        if want>=0 and idle:
            opened = true
            kind = want
            lt_live = false
            rt_live = false
            rt_tap = false
            tap_until = 0
            events.append(["OPEN",kind])
    if tap_until!=0:
        if now>tap_until: tap_until = 0
        elif can_tap and not opened:
            tap_until = 0
            events.append(["TAP",BALLS])
    return events

func cancel() -> void:
    opened = false
    lt_live = false
    rt_live = false
    rt_tap = false
    tap_until = 0

func reset() -> void:
    cancel()
    lt = false
    rt = false
