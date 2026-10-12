package com.godot.game;

import android.app.Activity;
import android.content.Intent;
import android.content.ActivityNotFoundException;
import android.os.Bundle;
import android.provider.DocumentsContract;
import android.widget.Toast;

/** Opens the system file manager, without changing game input or adding a menu. */
public final class PokeWildsFilesActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        Intent view = new Intent(Intent.ACTION_VIEW);
        view.setDataAndType(DocumentsContract.buildRootUri(getPackageName()+".documents", "root"), DocumentsContract.Root.MIME_TYPE_ITEM);
        view.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try { startActivity(view); }
        catch (ActivityNotFoundException e) { Toast.makeText(this,"Open Android Files and choose PokeWilds in its sidebar.",Toast.LENGTH_LONG).show(); }
        finish();
    }
}
