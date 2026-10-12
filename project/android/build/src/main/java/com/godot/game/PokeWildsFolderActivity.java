package com.godot.game;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.widget.Toast;

/** System folder selection only; no game input bindings are changed. */
public final class PokeWildsFolderActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        if(state==null) startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION|Intent.FLAG_GRANT_WRITE_URI_PERMISSION|Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION|Intent.FLAG_GRANT_PREFIX_URI_PERMISSION),71);
    }
    @Override protected void onActivityResult(int request,int result,Intent data) {
        super.onActivityResult(request,result,data);
        if(request==71) {
            if(result==RESULT_OK&&data!=null&&data.getData()!=null) {
                try { PokeWildsSharedFolder.select(data.getData(),data.getFlags()); }
                catch(Exception e) { Toast.makeText(this,"Folder access failed. Your local saves are safe.",Toast.LENGTH_LONG).show(); }
            }
            PokeWildsSharedFolder.selectionFinished();
            finish();
        }
    }
}
