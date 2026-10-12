package com.godot.game;

import android.database.Cursor;
import android.database.MatrixCursor;
import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract.Document;
import android.provider.DocumentsContract.Root;
import android.provider.DocumentsProvider;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;

/** Live game files in Android Files; no import/export copies or broad storage permission. */
public final class PokeWildsDocuments extends DocumentsProvider {
    private static final String[] ROOTS={Root.COLUMN_ROOT_ID,Root.COLUMN_DOCUMENT_ID,Root.COLUMN_TITLE,Root.COLUMN_FLAGS,Root.COLUMN_MIME_TYPES,Root.COLUMN_AVAILABLE_BYTES};
    private static final String[] DOCS={Document.COLUMN_DOCUMENT_ID,Document.COLUMN_DISPLAY_NAME,Document.COLUMN_MIME_TYPE,Document.COLUMN_SIZE,Document.COLUMN_LAST_MODIFIED,Document.COLUMN_FLAGS};
    @Override public boolean onCreate(){PokeWildsStorage.initialize(getContext());return true;}
    private File root() throws FileNotFoundException {
        try {
            File root=PokeWildsStorage.activeRoot(getContext());
            for(String name:new String[]{"saves","world_cache"}) {
                File folder=new File(root,name);
                if(!folder.isDirectory()&&!folder.mkdirs())throw new IOException("Cannot create "+name);
            }
            return root;
        }catch(IOException e){throw new FileNotFoundException(e.getMessage());}
    }
    private File resolve(String id) throws FileNotFoundException {
        try {
            File root=root().getCanonicalFile();File file=id.equals("root")?root:new File(root,id).getCanonicalFile();
            if(!file.equals(root)&&!file.getPath().startsWith(root.getPath()+File.separator))throw new FileNotFoundException("Invalid path");
            if(!id.equals("root")&&!id.equals("game.ini")&&!id.equals("saves")&&!id.startsWith("saves/")&&!id.equals("world_cache")&&!id.startsWith("world_cache/"))throw new FileNotFoundException("Not a shared game file");
            return file;
        }catch(IOException e){throw new FileNotFoundException(e.getMessage());}
    }
    private String id(File file) throws FileNotFoundException {
        try{return file.getCanonicalPath().substring(root().getCanonicalPath().length()+1).replace(File.separatorChar,'/');}
        catch(IOException e){throw new FileNotFoundException(e.getMessage());}
    }
    private void row(MatrixCursor out,String id,File file){
        MatrixCursor.RowBuilder row=out.newRow();
        for(String c:out.getColumnNames()){
            Object value=null;
            if(c.equals(Document.COLUMN_DOCUMENT_ID))value=id;
            else if(c.equals(Document.COLUMN_DISPLAY_NAME))value=id.equals("root")?"PokeWilds":file.getName();
            else if(c.equals(Document.COLUMN_MIME_TYPE))value=file.isDirectory()?Document.MIME_TYPE_DIR:file.getName().endsWith(".ini")?"text/plain":"application/octet-stream";
            else if(c.equals(Document.COLUMN_SIZE))value=file.length();
            else if(c.equals(Document.COLUMN_LAST_MODIFIED))value=file.lastModified();
            else if(c.equals(Document.COLUMN_FLAGS))value=file.isDirectory()?Document.FLAG_DIR_SUPPORTS_CREATE:Document.FLAG_SUPPORTS_WRITE|Document.FLAG_SUPPORTS_DELETE|Document.FLAG_SUPPORTS_RENAME;
            row.add(value);
        }
    }
    @Override public Cursor queryRoots(String[] projection) throws FileNotFoundException {
        File root=root();MatrixCursor out=new MatrixCursor(projection==null?ROOTS:projection);MatrixCursor.RowBuilder row=out.newRow();
        for(String c:out.getColumnNames()){
            Object value=null;
            if(c.equals(Root.COLUMN_ROOT_ID)||c.equals(Root.COLUMN_DOCUMENT_ID))value="root";
            else if(c.equals(Root.COLUMN_TITLE))value="PokeWilds";
            else if(c.equals(Root.COLUMN_FLAGS))value=Root.FLAG_SUPPORTS_CREATE|Root.FLAG_LOCAL_ONLY|Root.FLAG_SUPPORTS_IS_CHILD;
            else if(c.equals(Root.COLUMN_MIME_TYPES))value="*/*";
            else if(c.equals(Root.COLUMN_AVAILABLE_BYTES))value=root.getFreeSpace();
            row.add(value);
        }return out;
    }
    @Override public Cursor queryDocument(String documentId,String[] projection) throws FileNotFoundException {
        File file=resolve(documentId);if(!file.exists())throw new FileNotFoundException(documentId);
        MatrixCursor out=new MatrixCursor(projection==null?DOCS:projection);row(out,documentId,file);return out;
    }
    @Override public Cursor queryChildDocuments(String parent,String[] projection,String sort) throws FileNotFoundException {
        MatrixCursor out=new MatrixCursor(projection==null?DOCS:projection);File[] children=resolve(parent).listFiles();
        if(children!=null)for(File child:children){String id=id(child);try{resolve(id);row(out,id,child);}catch(FileNotFoundException ignored){}}
        return out;
    }
    @Override public ParcelFileDescriptor openDocument(String documentId,String mode,CancellationSignal signal) throws FileNotFoundException {
        return ParcelFileDescriptor.open(resolve(documentId),ParcelFileDescriptor.parseMode(mode));
    }
    @Override public String createDocument(String parent,String mime,String name) throws FileNotFoundException {
        if(name.isEmpty()||name.contains("/")||name.contains("\\")||name.equals(".")||name.equals(".."))throw new FileNotFoundException("Invalid filename");
        File file=new File(resolve(parent),name);String id=id(file);resolve(id);
        try{if(file.exists())throw new IOException("Already exists");if(Document.MIME_TYPE_DIR.equals(mime)){if(!file.mkdir())throw new IOException("Create failed");}else if(!file.createNewFile())throw new IOException("Create failed");return id;}
        catch(IOException e){throw new FileNotFoundException(e.getMessage());}
    }
    @Override public void deleteDocument(String documentId) throws FileNotFoundException {
        File file=resolve(documentId);if(file.isDirectory()||!file.delete())throw new FileNotFoundException("Cannot delete");
    }
    @Override public String renameDocument(String documentId,String name) throws FileNotFoundException {
        if(name.isEmpty()||name.contains("/")||name.contains("\\")||name.equals(".")||name.equals(".."))throw new FileNotFoundException("Invalid filename");
        File source=resolve(documentId);File dest=new File(source.getParentFile(),name);String id=id(dest);resolve(id);
        if(source.isDirectory()||dest.exists()||!source.renameTo(dest))throw new FileNotFoundException("Cannot rename");return id;
    }
    @Override public boolean isChildDocument(String parent,String child){
        try{return resolve(child).getCanonicalPath().startsWith(resolve(parent).getCanonicalPath()+File.separator);}catch(IOException e){return false;}
    }
}
