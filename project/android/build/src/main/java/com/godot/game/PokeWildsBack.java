package com.godot.game;

import androidx.annotation.Keep;
import java.util.concurrent.atomic.AtomicInteger;

/** UI-thread back callbacks are consumed once on Godot's game thread. */
@Keep
public final class PokeWildsBack {
    private static final AtomicInteger pending = new AtomicInteger(0);
    private PokeWildsBack() {}
    static void submit(boolean rightEdge) { pending.set(rightEdge ? 2 : 1); }
    @Keep
    public static int consumeEvent() { return pending.getAndSet(0); }
}
