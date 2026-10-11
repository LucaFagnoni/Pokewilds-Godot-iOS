package com.godot.game;

import android.content.Context;
import android.provider.DocumentsContract;
import java.io.File;
import java.io.IOException;

/** One authoritative live folder for the engine and the system Files provider. */
public final class PokeWildsStorage {
    private static Context context;
    public static synchronized void initialize(Context value) { context = value.getApplicationContext(); PokeWildsSharedFolder.initialize(value); }
    public static synchronized String getExternalRoot() {
        if (context == null) return "";
        File folder = context.getExternalFilesDir(null);
        return folder == null ? "" : folder.getAbsolutePath();
    }
    public static synchronized boolean setActiveRoot(String path) {
        if (context == null) return false;
        try {
            File selected = new File(path).getCanonicalFile();
            File internal = context.getFilesDir().getCanonicalFile();
            File external = context.getExternalFilesDir(null);
            boolean allowed = selected.equals(internal) || selected.getPath().startsWith(internal.getPath() + File.separator);
            if (external != null) allowed |= selected.equals(external.getCanonicalFile());
            if (!allowed || (!selected.isDirectory() && !selected.mkdirs())) return false;
            if (!context.getSharedPreferences("pokewilds_storage", Context.MODE_PRIVATE).edit().putString("active_root", selected.getPath()).commit()) return false;
            context.getContentResolver().notifyChange(DocumentsContract.buildRootsUri(context.getPackageName() + ".documents"), null);
            return true;
        } catch (IOException | SecurityException e) { return false; }
    }
    static synchronized File activeRoot(Context value) throws IOException {
        initialize(value);
        String saved = context.getSharedPreferences("pokewilds_storage", Context.MODE_PRIVATE).getString("active_root", "");
        File external = context.getExternalFilesDir(null);
        File internal = context.getFilesDir().getCanonicalFile();
        File selected = (saved.isEmpty() ? (external == null ? internal : external) : new File(saved)).getCanonicalFile();
        boolean allowed = selected.equals(internal) || selected.getPath().startsWith(internal.getPath() + File.separator);
        if (external != null) allowed |= selected.equals(external.getCanonicalFile());
        if (!allowed) throw new IOException("Invalid game storage path");
        if (!selected.isDirectory() && !selected.mkdirs()) throw new IOException("Game storage unavailable");
        return selected;
    }
}
