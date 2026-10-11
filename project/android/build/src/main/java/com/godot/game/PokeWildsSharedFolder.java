package com.godot.game;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.net.Uri;
import android.provider.DocumentsContract;
import java.io.*;
import java.security.MessageDigest;
import java.util.*;

/** SAF mirror. Imports happen before the title menu opens; exports are queued after writes. */
public final class PokeWildsSharedFolder {
    private static Context context;
    private static volatile boolean busy;
    private static volatile boolean choosing;
    private static volatile String error = "";
    private static final Map<String,String> localStamps = new HashMap<>();
    private static SharedPreferences prefs() { return context.getSharedPreferences("pokewilds_shared",0); }
    public static synchronized void initialize(Context c) { context=c.getApplicationContext(); }
    public static boolean configured() { return context!=null && !prefs().getString("tree", "").isEmpty(); }
    public static boolean busy() { return busy; }
    public static String error() { return error; }
    public static boolean choosing() { return choosing; }
    static void selectionFinished() { choosing=false; }
    public static void chooseFolder() {
        choosing=true;
        try { context.startActivity(new Intent(context,PokeWildsFolderActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); }
        catch(Exception e) { choosing=false; error="Cannot open Android folder picker: "+e.getMessage(); }
    }
    static void select(Uri uri, int flags) {
        context.getContentResolver().takePersistableUriPermission(uri, flags & (Intent.FLAG_GRANT_READ_URI_PERMISSION|Intent.FLAG_GRANT_WRITE_URI_PERMISSION));
        // A different tree must never inherit the old tree's sync fingerprints.
        prefs().edit().clear().putString("tree",uri.toString()).commit();
        localStamps.clear();
    }
    public static synchronized void synchronize(boolean importFiles) {
        if (busy || !configured()) return;
        busy=true; error="";
        new Thread(() -> {
            try {
                Uri tree=Uri.parse(prefs().getString("tree",""));
                Uri root=DocumentsContract.buildDocumentUriUsingTree(tree,DocumentsContract.getTreeDocumentId(tree));
                File local=PokeWildsStorage.activeRoot(context);
                syncDirectory(tree,root,local,"",importFiles);
            } catch(Exception e) { error="Save folder sync failed: "+e.getMessage()+". Local saves are retained."; }
            finally { busy=false; }
        },"PokeWilds-save-folder").start();
    }
    private static boolean allowed(String relative) {
        if (relative.equals("game.ini")) return true;
        if (!(relative.startsWith("saves/")||relative.startsWith("world_cache/"))) return false;
        String name=relative.substring(relative.lastIndexOf('/')+1);
        return !name.startsWith(".") && !name.endsWith(".tmp") && !name.endsWith(".migrating") && !name.endsWith(".syncing") && !name.contains(".conflict-");
    }
    private static Map<String,Uri> children(Uri tree,Uri directory) throws IOException {
        Map<String,Uri> entries=new TreeMap<>();
        Uri query=DocumentsContract.buildChildDocumentsUriUsingTree(tree,DocumentsContract.getDocumentId(directory));
        try(Cursor c=context.getContentResolver().query(query,new String[]{DocumentsContract.Document.COLUMN_DOCUMENT_ID,DocumentsContract.Document.COLUMN_DISPLAY_NAME},null,null,null)) {
            if(c==null) throw new IOException("Cannot read selected folder");
            while(c.moveToNext()) {
                String name=c.getString(1);
                if(name.equals(".")||name.equals("..")||name.contains("/")||name.contains("\\")) continue;
                entries.put(name,DocumentsContract.buildDocumentUriUsingTree(tree,c.getString(0)));
            }
        }
        return entries;
    }
    private static void syncDirectory(Uri tree,Uri remote,File local,String prefix,boolean importing) throws Exception {
        if(!local.isDirectory()&&!local.mkdirs()) throw new IOException("Cannot create local save directory");
        Map<String,Uri> entries=children(tree,remote);
        if(prefix.isEmpty()) {
            syncFile(remote,entries.get("game.ini"),new File(local,"game.ini"),"game.ini",importing);
            for(String folder:new String[]{"saves","world_cache"}) {
                Uri sub=entries.get(folder);
                if(sub==null) sub=DocumentsContract.createDocument(context.getContentResolver(),remote,DocumentsContract.Document.MIME_TYPE_DIR,folder);
                if(sub==null) throw new IOException("Cannot create "+folder);
                syncDirectory(tree,sub,new File(local,folder),folder+"/",importing);
            }
            return;
        }
        Set<String> names=new TreeSet<>(entries.keySet());
        String[] files=local.list(); if(files!=null) names.addAll(Arrays.asList(files));
        for(String name:names) {
            String relative=prefix+name;
            if(!allowed(relative)) continue;
            File file=new File(local,name);
            if(file.isDirectory()) continue; // Engine saves and caches are flat directories.
            syncFile(remote,entries.get(name),file,relative,importing);
        }
    }
    private static String digest(InputStream input) throws Exception {
        if(input==null) throw new IOException("Cannot open document");
        try(InputStream in=input) {
            MessageDigest md=MessageDigest.getInstance("SHA-256"); byte[] buffer=new byte[65536]; int n;
            while((n=in.read(buffer))!=-1) md.update(buffer,0,n);
            StringBuilder out=new StringBuilder();for(byte b:md.digest()) out.append(String.format(Locale.ROOT,"%02x",b&255));return out.toString();
        }
    }
    private static void copy(InputStream input,OutputStream output) throws IOException {
        if(input==null||output==null) throw new IOException("Cannot open save document");
        try(InputStream in=input;OutputStream out=output) { byte[] buffer=new byte[65536]; int n;while((n=in.read(buffer))!=-1)out.write(buffer,0,n);out.flush(); }
    }
    private static void syncFile(Uri directory,Uri remote,File local,String relative,boolean importing) throws Exception {
        String stamp=local.isFile()?local.length()+":"+local.lastModified():"missing";
        if(!importing && stamp.equals(localStamps.get(relative))) return;
        String baseline=prefs().getString("hash:"+relative,"");
        String ours=local.isFile()?digest(new FileInputStream(local)):"";
        String theirs=remote==null?"":digest(context.getContentResolver().openInputStream(remote));
        if(ours.equals(theirs)) { remember(relative,ours,local); return; }
        if(importing && remote!=null && !theirs.equals(baseline)) {
            File temp=new File(local.getPath()+".syncing");
            copy(context.getContentResolver().openInputStream(remote),new FileOutputStream(temp));
            if(!theirs.equals(digest(new FileInputStream(temp)))) throw new IOException("Save changed during import; retry on next launch");
            if(local.isFile() && !ours.equals(baseline)) {
                File backup=new File(local.getPath()+".conflict-"+System.currentTimeMillis());
                copy(new FileInputStream(local),new FileOutputStream(backup));
            }
            // Same filesystem atomic replacement; original stays intact on failure.
            android.system.Os.rename(temp.getPath(),local.getPath());
            remember(relative,theirs,local);return;
        }
        if(remote!=null && !theirs.equals(baseline)) {
            // External edits are imported next launch, never overwritten mid-game.
            throw new IOException("External change in "+relative+"; restart to load it");
        }
        if(!local.isFile()) return; // Never silently delete a user's shared save.
        File snapshot=new File(local.getPath()+".syncing");
        copy(new FileInputStream(local),new FileOutputStream(snapshot));
        if(!stamp.equals(local.length()+":"+local.lastModified()) || !ours.equals(digest(new FileInputStream(snapshot)))) { snapshot.delete(); return; }
        String name=local.getName();
        Uri temp=null, previous=null;
        boolean installed=false;
        try {
            temp=DocumentsContract.createDocument(context.getContentResolver(),directory,"application/octet-stream","."+name+".syncing-"+System.currentTimeMillis());
            if(temp==null) throw new IOException("Cannot create shared save");
            copy(new FileInputStream(snapshot),context.getContentResolver().openOutputStream(temp,"wt"));
            if(!ours.equals(digest(context.getContentResolver().openInputStream(temp)))) throw new IOException("Shared save verification failed");
            if(remote!=null) {
                previous=DocumentsContract.renameDocument(context.getContentResolver(),remote,"."+name+".previous-"+System.currentTimeMillis());
                if(previous==null) throw new IOException("Folder provider cannot safely replace saves");
            }
            Uri result=DocumentsContract.renameDocument(context.getContentResolver(),temp,name);
            if(result==null) throw new IOException("Folder provider cannot install save");
            installed=true;
            remember(relative,ours,local);
            localStamps.put(relative,stamp); // A concurrent newer write still needs exporting.
        } catch(Exception e) {
            if(previous!=null && !installed) DocumentsContract.renameDocument(context.getContentResolver(),previous,name);
            throw e;
        } finally {
            snapshot.delete();
            // Cleanup failure must not roll back a successfully verified save.
            try {
                if(installed && previous!=null) DocumentsContract.deleteDocument(context.getContentResolver(),previous);
                if(!installed && temp!=null) DocumentsContract.deleteDocument(context.getContentResolver(),temp);
            } catch(Exception ignored) { }
        }
    }
    private static void remember(String relative,String hash,File local) {
        prefs().edit().putString("hash:"+relative,hash).commit();
        localStamps.put(relative,local.isFile()?local.length()+":"+local.lastModified():"missing");
    }
}
