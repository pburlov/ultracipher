package burlov.ultracipher;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.Dialog;
import android.app.ProgressDialog;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ActivityInfo;
import android.content.res.Configuration;
import android.os.AsyncTask;
import android.os.Bundle;
import android.os.Environment;
import android.text.Editable;
import android.text.TextWatcher;
import android.util.Log;
import android.view.ContextMenu;
import android.view.ContextMenu.ContextMenuInfo;
import android.view.Menu;
import android.view.MenuInflater;
import android.view.MenuItem;
import android.view.View;
import android.view.ViewGroup;
import android.widget.AdapterView;
import android.widget.AdapterView.AdapterContextMenuInfo;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.ListView;
import android.widget.TextView;
import android.widget.Toast;

import org.apache.commons.io.FileUtils;
import org.apache.commons.io.IOUtils;
import org.apache.commons.lang3.StringUtils;

import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.io.ObjectInputStream;
import java.io.ObjectOutputStream;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import de.burlov.ultracipher.core.DataEntry;
import de.burlov.ultracipher.core.Finder;
import de.burlov.ultracipher.core.ICryptor;
import de.burlov.ultracipher.core.IProgressListener;
import de.burlov.ultracipher.core.KeyGenPerformanceLevel;
import de.burlov.ultracipher.core.Ultracipher;
import de.burlov.ultracipher.core.Ultracipher.SyncResult;
import de.burlov.ultracipher.core.mail.EmailCredentials;

public class SearchActivity extends Activity {
    //TODO wieder hoch setzten
    //	private static final KeyGenPerformanceLevel KEY_GEN_PERFORMANCE_LEVEL = new KeyGenPerformanceLevel(16, 8, 1);
    public final static String LOG_TAG = "Ultracipher";
    static final int DELETE_CONFIRMATION_DIALOG = 2;
    private static final String US_ASCII = "US-ASCII";
    private static final String RECENT_LIST_FILE = "recentList.dat";
    private static final KeyGenPerformanceLevel KEY_GEN_PERFORMANCE_LEVEL = KeyGenPerformanceLevel.DEFAULT;// new KeyGenPerformanceLevel(16384, 8, 1);
    private static final String DATA_FILE = "ultracipher.dat";
    private static final String RECENT_ENTRIES_KEY = "RecentEntries";
    private TextView searchField = null;
    private ListView listView;
    private Ultracipher core = new Ultracipher(null);
    private DataEntry entryToDelete;
    private AsyncTask<?, ?, ?> runningTask;
    private Finder finder = new Finder();
    private List<String> recentEntries;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        this.setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT);
        System.out.println("SearchActivity.onCreate");
        recentEntries = loadRecentEntryList();
        setContentView(R.layout.search);
        searchField = (TextView) findViewById(R.id.searchField);
        listView = (ListView) findViewById(R.id.searchResults);
        registerForContextMenu(listView);
        searchField.addTextChangedListener(new TextWatcher() {

            @Override
            public void onTextChanged(CharSequence s, int start, int before, int count) {
            }

            @Override
            public void beforeTextChanged(CharSequence s, int start, int count, int after) {
            }

            @Override
            public void afterTextChanged(Editable s) {
                searchForString(searchField.getText());
            }
        });
        listView.setOnItemClickListener(new AdapterView.OnItemClickListener() {

            @Override
            public void onItemClick(AdapterView<?> arg0, View arg1, int pos, long id) {
                showEntry((DataEntry) listView.getItemAtPosition(pos));
            }

        });
        loadLocalDbFirstTime();
    }

    private SharedPreferences getPreferences() {
        SharedPreferences preferences = getSharedPreferences("ultacipher", MODE_PRIVATE);
        return preferences;
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        // The activity is about to be destroyed.
        if (runningTask != null) {
            runningTask.cancel(true);
        }
        /*
         * 'Recent' List von evt nicht mehr vorhandenen Eintraegen saeubern
		 */
        ArrayList<String> newList = new ArrayList<String>();
        Map<String, DataEntry> entries = core.getDatabase().getEntryMap();
        for (String id : recentEntries) {
            if (entries.containsKey(id)) {
                newList.add(id);
            }
        }
        recentEntries = newList;
        saveRecentEntryList();
        // Log.v("", "onDestroy");
    }

    private void loadLocalDbFirstTime() {
        final String pem = loadPem();
        if (pem == null) {
            /*
			 * Noch keine lokale Daten gespeichert, also
			 * Passwortinitialisierungsdialog zeigen
			 */
            initCryptor(null, true);
        } else {
            decryptDatabaseAsync(pem, new EmptyFunction<Boolean>());
        }
    }

    private AlertDialog createYesNoDialog(String text, final Function<Boolean> callback) {
        AlertDialog.Builder builder = new AlertDialog.Builder(this);
        builder.setMessage(text).setCancelable(false).setPositiveButton("Yes", new DialogInterface.OnClickListener() {
            @Override
            public void onClick(DialogInterface dialog, int id) {
                dialog.dismiss();
                callback.apply(true);
            }
        }).setNegativeButton("No", new DialogInterface.OnClickListener() {
            @Override
            public void onClick(DialogInterface dialog, int id) {
                dialog.dismiss();
                callback.apply(false);
            }
        });
        AlertDialog alert = builder.create();
        return alert;
    }

    private void searchForString(CharSequence s) {
        Log.d(LOG_TAG, "search: " + s);
        if (s.toString().trim().length() > 0) {
            List<DataEntry> entries = core.getDatabase().getEntries();
            entries = finder.findEntries(s.toString(), entries, 100);
            initEntryList(entries);
        } else {
            initEntryList();
        }
    }

    /**
     * Callback Methode fuer die Menu der Activity
     *
     * @param featureId
     * @param item
     * @return
     */
    @Override
    public boolean onMenuItemSelected(int featureId, MenuItem item) {
        switch (item.getItemId()) {
            case R.id.menuItemCreateEntry:
                createNewDataEntry();
                break;
            case R.id.menuItemChangePassphrase:
                initCryptor(new Function<Void>() {
                    @Override
                    public void apply(Void arg) {
                        // Nach der Passwortaenderung Daten mit neuem Schluessel
                        // speichern
                        saveDatabaseLocalAsync();
                    }
                }, true);
                break;
            case R.id.menuItemSyncAccount:
                createSyncAccountDialog(new Function<Void>() {
                    @Override
                    public void apply(Void arg) {
                        saveDatabaseLocalAsync();
                    }
                }).show();
                break;
            case R.id.menuItemDownloadData:
                downloadDataAsync(new EmptyFunction<Void>());
                break;
            case R.id.menuItemUploadData:
                uploadDataAsync();
                break;
            case R.id.menuItemPerformance:
                measurePerformanceAsync();
                break;
            case R.id.menuItemAbout:
                createMessageDialog(getResources().getString(R.string.programInfo)).show();
                break;
            case R.id.menuItemExit:
                this.finish();
                break;
        }
        return super.onMenuItemSelected(featureId, item);
    }

    public void showInfo(String text) {
        int duration = Toast.LENGTH_SHORT;
        Toast toast = Toast.makeText(this, text, duration);
        toast.show();
    }

    public void showInfo(int text) {
        int duration = Toast.LENGTH_SHORT;
        Toast toast = Toast.makeText(this, text, duration);
        toast.show();
    }

    private void measurePerformanceAsync() {
        final ProgressDialog progressDialog = ProgressDialog.show(this, "", "Performance test...");
        final long start = System.currentTimeMillis();
        AsyncTask<Void, Void, Double> asyncTask = new AsyncTask<Void, Void, Double>() {

            @Override
            protected void onPostExecute(Double obj) {
                Log.i(LOG_TAG, "performance test completed in " + (System.currentTimeMillis() - start) + "ms");
                progressDialog.dismiss();
                createMessageDialog("Performance index: " + obj.floatValue()).show();
            }

            @Override
            protected Double doInBackground(Void... params) {
                return Ultracipher.measurePerformance();
            }
        };
        runningTask = asyncTask;
        asyncTask.execute(null, null);
    }

    private void createNewDataEntry() {
        DataEntry entry = new DataEntry();
        Intent intent = new Intent(this, EditDataEntryActivity.class);
        intent.putExtra("entry", entry);
        intent.putExtra("requestCode", EditDataEntryActivity.INTENT_NEW_DATA_ENTRY);
        addRecentSelectedItem(entry.getId());
        startActivityForResult(intent, EditDataEntryActivity.INTENT_NEW_DATA_ENTRY);
    }

    private void showEntry(DataEntry entry) {
        Intent intent = new Intent(this, EditDataEntryActivity.class);
        intent.putExtra("entry", entry);
        intent.putExtra("requestCode", EditDataEntryActivity.INTENT_SHOW_DATA_ENTRY);
        addRecentSelectedItem(entry.getId());
        startActivityForResult(intent, EditDataEntryActivity.INTENT_SHOW_DATA_ENTRY);

    }
    private void addRecentSelectedItem(String id) {
        if (id == null) {
            return;
        }
        recentEntries.remove(id);
        recentEntries.add(0, id);
    }

    private boolean checkCryptor(final Function<Void> callback) {
        if (core.getCurrentCryptor() == null) {
            initCryptor(new Function<Void>() {

                @Override
                public void apply(Void arg) {
                    callback.apply(null);
                }
            }, false);
            // showError("No cryptor initialized", null);
            return false;
        }
        return true;
    }

    private boolean checkEmailCredentials(final Function<Void> callback) {
        if (core.getSyncCredentials() == null) {
            createSyncAccountDialog(new Function<Void>() {
                @Override
                public void apply(Void arg) {
                    callback.apply(null);
                }
            }).show();
            return false;
        }
        return true;
    }

    private void downloadDataAsync(final Function<Void> callback) {
        Function<Void> f = new Function<Void>() {
            @Override
            public void apply(Void arg) {
                downloadDataAsync(callback);
            }
        };
        if (!checkEmailCredentials(f)) {
            return;
        }
        if (!checkCryptor(f)) {
            return;
        }
        final ProgressDialog progressDialog = ProgressDialog.show(this, "", "Download...");
        final long start = System.currentTimeMillis();
        AsyncTask<Void, Void, Object> asyncTask = new AsyncTask<Void, Void, Object>() {

            @Override
            protected void onPostExecute(Object obj) {
                Log.i(LOG_TAG, "Download completed in " + (System.currentTimeMillis() - start) + "ms");
                progressDialog.dismiss();
                if (obj == SyncResult.NoData) {
                    showNotification("No data found! Is passphrase correct?", true);
                } else if (obj instanceof Exception) {
                    showError("Download failed", ((Exception) obj));
                    return;
                } else if (obj == SyncResult.NoChanges) {
                    showNotification("No changes found", false);
                } else {
                    showNotification("Download completed", false);
                }
                initEntryList();
                callback.apply(null);
            }

            @Override
            protected Object doInBackground(Void... params) {
                try {
                    SyncResult result = core.syncDatabase(true);
                    if (result == SyncResult.IncomingChanges || result == SyncResult.OutgoingChanges) {
                        String pem = core.exportAsPemObject();
                        savePem(pem);
                    }
                    return result;
                } catch (Exception e) {
                    Log.e(LOG_TAG, e.toString());
                    return e;
                }
            }
        };
        runningTask = asyncTask;
        asyncTask.execute(null, null);

    }

    private void showNotification(String msg, boolean durationLong) {
        Toast toast = Toast.makeText(this, msg, durationLong ? Toast.LENGTH_LONG : Toast.LENGTH_SHORT);
        toast.show();
    }

    private void uploadDataAsync() {
        Function<Void> f = new Function<Void>() {
            @Override
            public void apply(Void arg) {
                uploadDataAsync();
            }
        };
        if (!checkEmailCredentials(f)) {
            return;
        }
        if (!checkCryptor(f)) {
            return;
        }
        final ProgressDialog progressDialog = ProgressDialog.show(this, "", "Uploading...");
        final long start = System.currentTimeMillis();
        AsyncTask<Void, Void, Object> asyncTask = new AsyncTask<Void, Void, Object>() {

            @Override
            protected void onPostExecute(Object obj) {
                Log.i(LOG_TAG, "Upload completed in " + (System.currentTimeMillis() - start) + "ms");
                progressDialog.dismiss();
                if (obj instanceof Exception) {
                    showError("Upload failed", ((Exception) obj));
                    return;
                }
                showNotification("Upload completed", false);
            }

            @Override
            protected Object doInBackground(Void... params) {
                try {
                    core.save(core.getSyncCredentials());
                    return null;
                } catch (Exception e) {
                    Log.e(LOG_TAG, e.toString());
                    return e;
                }
            }
        };
        runningTask = asyncTask;
        asyncTask.execute(null, null);
    }

    /**
     * Callback Methode fuer Context-Menu der Datenbankeintraege
     *
     * @param item
     * @return
     */
    @Override
    public boolean onContextItemSelected(MenuItem item) {
        AdapterContextMenuInfo info = (AdapterContextMenuInfo) item.getMenuInfo();
        DataEntry entry = (DataEntry) listView.getAdapter().getItem(info.position);
        entryToDelete = entry;
        if (entry == null) {
            return false;
        }
        showDialog(DELETE_CONFIRMATION_DIALOG);
        return true;
    }

    @Override
    public void onConfigurationChanged(Configuration newConfig) {
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        switch (requestCode) {
            case EditDataEntryActivity.INTENT_NEW_DATA_ENTRY:
            case EditDataEntryActivity.INTENT_SHOW_DATA_ENTRY: {
                if (data == null) {
                    //hat sich nichts geaendert
                    return;
                }
                DataEntry dataEntry = (DataEntry) data.getSerializableExtra("entry");
                if (dataEntry == null) {
                    return;
                }
                if (dataEntry.getId() == null && (!dataEntry.getName().isEmpty() || !dataEntry.getTags().isEmpty() || !dataEntry.getText().isEmpty())) {
                    //Nur dann speichern wenn irgendwas eingetragen wurde
                    DataEntry newEntry = core.getDatabase().addNewEntry(dataEntry);
                    Log.v(LOG_TAG, newEntry.toString());
                } else {
                    DataEntry oldEntry = core.getDatabase().getEntryMap().get(dataEntry.getId());
                    if (oldEntry != null && !oldEntry.equals(dataEntry)) {
                        //Nur dann speichern wenn der Eintrag geaendert wurde
                        oldEntry.setTags(dataEntry.getTags());
                        oldEntry.setName(dataEntry.getName());
                        oldEntry.setText(dataEntry.getText());
                        oldEntry.setLastChanged(System.currentTimeMillis());
                    }
                }
                initEntryList();
                saveDatabaseLocalAsync();
            }

        }
        super.onActivityResult(requestCode, resultCode, data);

    }

    /**
     * Initialisiert ListView mit allen vorhandenen Eintraegen. Die Eintraegen
     * werden vorsortiert.
     */
    private void initEntryList() {
        List<DataEntry> sortEntryList = sortEntryList(core.getDatabase().getEntryMap());
        initEntryList(sortEntryList);
    }

    /**
     * Sortiert die Liste der Eintraege um die haeufiger aufgerufene Eintrage
     * zuerst einzuzeigen
     *
     * @param entries
     * @return
     */
    private List<DataEntry> sortEntryList(Map<String, DataEntry> entries) {
        if (recentEntries == null) {
            return new ArrayList<DataEntry>(entries.values());
        }
        LinkedHashMap<String, DataEntry> sortedEntries = new LinkedHashMap<String, DataEntry>(entries.size(), 0.75f, false);
		/*
		 * Zuerst die zuletzt aufgerufene Eintraege einfuegen
		 */
        for (String id : recentEntries) {
            DataEntry entry = entries.get(id);
            if (entry != null) {
                sortedEntries.put(id, entry);
            }
        }
		/*
		 * Danach den Rest
		 */
        sortedEntries.putAll(entries);
        return new ArrayList<DataEntry>(sortedEntries.values());
    }

    /**
     * Initialisiert ListView mit gegebenen Eintraegen. Die Liste wird dargestellt
     * wie angegeben.
     */
    private void initEntryList(List<DataEntry> entries) {

        ArrayAdapter<DataEntry> adapter = new ArrayAdapter<DataEntry>(this, android.R.layout.simple_list_item_1, entries) {

            @Override
            public View getView(int position, View convertView, ViewGroup parent) {
                View ret = super.getView(position, convertView, parent);
//				if (ret instanceof TextView) {
//					((TextView) ret).setTypeface(CURRENT_FONT);
//				}
                return ret;
            }

        };
        listView.setAdapter(adapter);
    }

    @Override
    protected Dialog onCreateDialog(int id) {
        Dialog dialog = null;
        switch (id) {
            case DELETE_CONFIRMATION_DIALOG:
                dialog = createDeleteConfirmationDialog();
                break;
        }
        return dialog;
    }

    private Dialog createMessageDialog(String msg) {
        AlertDialog.Builder builder = new AlertDialog.Builder(this);
        builder.setMessage(msg).setCancelable(false).setPositiveButton(android.R.string.ok, null);
        AlertDialog alert = builder.create();
        return alert;

    }

    private Dialog createDeleteConfirmationDialog() {
        AlertDialog.Builder builder = new AlertDialog.Builder(this);
        builder.setMessage(R.string.delete_entry_confirmation).setCancelable(false)
                .setPositiveButton(android.R.string.yes, new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int id) {
                        if (entryToDelete != null) {
                            core.getDatabase().deleteEntry(entryToDelete);
                            entryToDelete = null;
                            initEntryList();
                            saveDatabaseLocalAsync();
                        }
                    }
                }).setNegativeButton(android.R.string.no, new DialogInterface.OnClickListener() {
            @Override
            public void onClick(DialogInterface dialog, int id) {
                dialog.cancel();
            }
        });
        AlertDialog alert = builder.create();
        return alert;
    }

    @Override
    public boolean onCreateOptionsMenu(Menu menu) {
        getMenuInflater().inflate(R.menu.activity_search, menu);
        MenuItem item = menu.findItem(R.id.menuItemDownloadData);
        item.setEnabled(true);
        item = menu.findItem(R.id.menuItemUploadData);
        item.setEnabled(true);
        return super.onCreateOptionsMenu(menu);
    }

    @Override
    public void onCreateContextMenu(ContextMenu menu, View v, ContextMenuInfo menuInfo) {
        super.onCreateContextMenu(menu, v, menuInfo);
        MenuInflater inflater = getMenuInflater();
        inflater.inflate(R.menu.entry_menu, menu);
    }

    /**
     * Speichert asynchron Datenbank. Bei Bedarf wird Passworteingabedialog
     * eingeblendet
     */
    private void saveDatabaseLocalAsync() {
        encryptDatabaseAsync(new Function<String>() {
            @Override
            public void apply(String pem) {
                try {
                    savePem(pem);
                } catch (Exception e) {
                    Log.e(LOG_TAG, "save failed: " + e.getMessage());
                    showError("Save failed", e);
                }
            }
        });
    }

    private void savePem(String pem) throws Exception {
        try {
            _savePemInInternalStorage(pem);
        } finally {
            _savePemInExternalStorage(pem);
        }
    }

    private void _savePemInInternalStorage(String pem) throws Exception {
        File dir = getFilesDir();
        saveDatabase(new File(dir, DATA_FILE), pem);
    }

    private void _savePemInExternalStorage(String pem) throws Exception {
        String storageState = Environment.getExternalStorageState();
        if (!Environment.MEDIA_MOUNTED.equals(storageState)) {
            Log.i(LOG_TAG, "no external storage found");
            return;
        }
        saveDatabase(getExternalStorageDataFile(), pem);
    }

    private File getExternalStorageDataFile() {
        File externalStorageDirectory = new File(Environment.getExternalStorageDirectory(), "Android/data/ultracipher");
        File file = new File(externalStorageDirectory, DATA_FILE);
        return file;
    }

    /**
     * Speichert aktuell geladene Datenbank in die angegebene Datei.
     * Falls die Datei schon existiert, wird die alte Datei zur Sicherung umbenannt
     *
     * @param destination
     * @throws java.io.IOException
     */
    synchronized public void saveDatabase(File destination, String data) throws Exception {
        File temp = createTempFile(destination.getParentFile(), destination.getName());
        if (destination.exists()) {
            //Alte Datei sichern
            Log.i(LOG_TAG, "Backup previous database as " + temp.getAbsolutePath());
            FileUtils.moveFile(destination, temp);
        }
        try {
            Log.i(LOG_TAG, "Write data to " + destination.getAbsolutePath());
            FileUtils.write(destination, data, "US-ASCII");
        } catch (IOException e) {
            Log.e(LOG_TAG, "Write data failed", e);
            Log.i(LOG_TAG, "Restore previous database from " + temp.getAbsolutePath());
            //Gesicherte Datei wiederherstellen
            FileUtils.deleteQuietly(destination);
            FileUtils.moveFile(temp, destination);
        }
    }

    File createTempFile(File dir, String baseName) {
        File file = null;
        long counter = System.currentTimeMillis();
        do {
            file = new File(dir, counter + "-" + baseName);
            counter++;
        } while (file.exists());
        return file;
    }


    /**
     * Zuerst versucht Daten von der externe Storage zu laden. Falls dies
     * misslingt, dann versucht Daten von interner Storage zu laden.
     *
     * @return
     */
    private String loadPem() {
        String pemObject = null;
        File file = getExternalStorageDataFile();
        if (file.exists() && Environment.MEDIA_MOUNTED.equals(Environment.getExternalStorageState())) {
            try {
                pemObject = FileUtils.readFileToString(file, US_ASCII);
                Log.i(LOG_TAG, "data loaded from " + file.getAbsolutePath());
                return pemObject;
            } catch (IOException ioe) {
                Log.e(LOG_TAG, "failed to load data from " + file.getAbsolutePath(), ioe);
            }
        }
        InputStream input = null;
        try {
            input = openFileInput(DATA_FILE);
            pemObject = IOUtils.toString(input, US_ASCII);
            Log.i(LOG_TAG, "data loaded from internal storage");
        } catch (FileNotFoundException fnf) {
            Log.i(LOG_TAG, "no data found on internal storage");
            // Nichts tun.
        } catch (IOException ioe) {
            Log.w(LOG_TAG, "failed to load data from internal storage", ioe);
        } finally {
            IOUtils.closeQuietly(input);
        }
        return pemObject;
    }

    private List<String> loadRecentEntryList() {
        try {
            Log.i(LOG_TAG, "loading recent list file");
            ObjectInputStream input = new ObjectInputStream(openFileInput(RECENT_LIST_FILE));
            return (List<String>) input.readObject();
        } catch (Exception fnf) {
            // Nichts tun.
            Log.w(LOG_TAG, "load recent list failed: " + fnf.getMessage());
            return new ArrayList<String>();
        }
    }

    private void saveRecentEntryList() {
        try {
            ObjectOutputStream oo = new ObjectOutputStream(openFileOutput(RECENT_LIST_FILE, Context.MODE_PRIVATE));
            oo.writeObject(recentEntries);
            oo.close();
        } catch (IOException e) {
            // TODO Auto-generated catch block
            e.printStackTrace();
        }
    }

    private void encryptDatabaseAsync(final Function<String> callback) {
        if (core.getCurrentCryptor() == null) {
            initCryptor(new Function<Void>() {
                @Override
                public void apply(Void arg) {
                    encryptDatabaseAsync(callback);
                }
            }, true);
            return;
        }
        final ProgressDialog progressDialog = ProgressDialog.show(this, "", "Encrypting...");
        final long start = System.currentTimeMillis();
        AsyncTask<Void, Void, String> asyncTask = new AsyncTask<Void, Void, String>() {

            @Override
            protected void onPostExecute(String obj) {
                Log.i(LOG_TAG, "Encrypting completed in " + (System.currentTimeMillis() - start) + "ms");
                progressDialog.dismiss();
                callback.apply(obj);
            }

            @Override
            protected String doInBackground(Void... params) {
                try {
                    return core.exportAsPemObject();
                } catch (Exception e) {
                    Log.e(LOG_TAG, e.toString());
                }
                return null;
            }
        };
        runningTask = asyncTask;
        asyncTask.execute(null, null);
    }

    /**
     * Importiert Daten von dem gegebenem PEM-Objekt und anschliesend
     * initialisiert die Result-List in GUI. Bei Bedarf wird Passworteingabedialog
     * gezeigt.
     *
     * @param pemObject
     * @param callback
     */
    private void decryptDatabaseAsync(final String pemObject, final Function<Boolean> callback) {
        if (core.getCurrentCryptor() == null) {
            initCryptor(new Function<Void>() {

                @Override
                public void apply(Void arg) {
                    decryptDatabaseAsync(pemObject, callback);
                }
            }, false);
            // showError("No cryptor initialized", null);
            return;
        }
        final ProgressDialog progressDialog = ProgressDialog.show(this, "", "Decrypting...");
        final long start = System.currentTimeMillis();
        AsyncTask<Void, Void, Exception> asyncTask = new AsyncTask<Void, Void, Exception>() {

            @Override
            protected void onPostExecute(Exception obj) {
                Log.i(LOG_TAG, "decrypting completed in " + (System.currentTimeMillis() - start) + "ms");
                progressDialog.dismiss();
                if (obj != null) {
					/*
					 * Ein Fehler ist passiert. Hoffentlich nur fasches Passwort
					 */
                    createYesNoDialog("Wrong passphrase. Retry?", new Function<Boolean>() {
                        @Override
                        public void apply(Boolean yes) {
                            if (yes) {
                                // Noch mal rekusiv versuchen
                                core.setCryptor(null);
                                decryptDatabaseAsync(pemObject, callback);
                            } else {
                                core.setCryptor(null);
                            }
                        }
                    }).show();
                    callback.apply(false);
                    return;
                } else {
                    initEntryList();
                }
                callback.apply(true);
            }

            @Override
            protected Exception doInBackground(Void... params) {
                try {
                    core.importFromPemObject(pemObject);
                } catch (Exception e) {
                    Log.e(LOG_TAG, e.toString());
                    return e;
                }
                return null;
            }
        };
        runningTask = asyncTask;
        asyncTask.execute(null, null);

    }

    private void showError(final String msg, final Throwable th) {
        Log.e(LOG_TAG, msg, th);
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                Dialog dialog = createMessageDialog(th.getMessage());
                dialog.setTitle(msg);
                dialog.show();
            }
        });
    }

    private Dialog createPasswordDialog(final Function<CharSequence> callBack) {
        final Dialog dialog = new Dialog(this);

        dialog.setContentView(R.layout.login_dialog);
        dialog.setTitle("Passphrase");

        Button bt = (Button) dialog.findViewById(R.id.buttonOk);
        bt.setOnClickListener(new View.OnClickListener() {

            @Override
            public void onClick(View v) {
                callBack.apply(((TextView) dialog.findViewById(R.id.tfPassword)).getText());
                dialog.dismiss();
            }
        });
        dialog.setOwnerActivity(this);
        return dialog;
    }

    /**
     * Initialisiert Passwortdialog mit Bestaetigungsfeld
     *
     * @param callBack
     * @return
     */
    private Dialog createCreatePasswordDialog(final Function<CharSequence> callBack) {
        final Dialog dialog = new Dialog(this);

        dialog.setContentView(R.layout.createpassphrase);
        dialog.setTitle("Enter the new passphrase");

        Button bt = (Button) dialog.findViewById(R.id.buttonOk);
        bt.setOnClickListener(new View.OnClickListener() {

            @Override
            public void onClick(View v) {
                CharSequence pass = ((TextView) dialog.findViewById(R.id.passphrase)).getText();
                CharSequence confirm = ((TextView) dialog.findViewById(R.id.passphraseConfirm)).getText();
                if (pass.toString().equals(confirm.toString())) {
                    callBack.apply(pass);
                    dialog.dismiss();
                } else {
                    dialog.setTitle("Passphrases not matching");
                }
            }
        });
        dialog.setOwnerActivity(this);
        return dialog;
    }

    private Dialog createSyncAccountDialog(final Function<Void> callback) {
        final Dialog dialog = new Dialog(this);
        dialog.setContentView(R.layout.syn_account);
        dialog.setTitle("Sync email account");
        TextView textEmail = (TextView) dialog.findViewById(R.id.textEmail);
        TextView textPassword = (TextView) dialog.findViewById(R.id.textPasswort);
        if (core.getSyncCredentials() != null) {
            textEmail.setText(core.getSyncCredentials().getEmailaddress());
            textPassword.setText(core.getSyncCredentials().getPassword());
        }
        Button bt = (Button) dialog.findViewById(R.id.buttonOk);
        bt.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                String email = ((TextView) dialog.findViewById(R.id.textEmail)).getText().toString();
                String password = ((TextView) dialog.findViewById(R.id.textPasswort)).getText().toString();
                if (StringUtils.isNotBlank(email)) {
                    core.setSyncCredentials(new EmailCredentials(email, password));
                } else {
                    core.setSyncCredentials(null);
                }
                dialog.dismiss();
                callback.apply(null);
            }
        });
        bt = (Button) dialog.findViewById(R.id.buttonCancel);
        bt.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                dialog.dismiss();
            }
        });
        dialog.setOwnerActivity(this);
        return dialog;
    }

    private void initCryptor(final Function<Void> callback, boolean confirmPassphrase) {
        Dialog dlg = null;
        Function<CharSequence> callBack2 = new Function<CharSequence>() {

            @Override
            public void apply(CharSequence arg) {
				/*
				 * Benutzer hat 'Ok' Button geklickt
				 */
                initCryptor(arg, new Function<ICryptor>() {
                    @Override
                    public void apply(ICryptor arg) {
                        core.setCryptor(arg);
                        if (callback != null) {
                            callback.apply(null);
                        }
                    }
                });
            }
        };
        if (confirmPassphrase) {
            dlg = createCreatePasswordDialog(callBack2);
        } else {
            dlg = createPasswordDialog(callBack2);
        }
        dlg.show();
    }

    private void initCryptor(CharSequence passphrase, final Function<ICryptor> callback) {
        final ProgressDialog progressDialog = new ProgressDialog(this);
        progressDialog.setTitle("Generate key");
        progressDialog.setCancelable(false);
        progressDialog.setMax(100);
        progressDialog.setProgressStyle(ProgressDialog.STYLE_HORIZONTAL);
        progressDialog.setOwnerActivity(this);
        progressDialog.show();
        final long start = System.currentTimeMillis();
        AsyncTask<CharSequence, Integer, ICryptor> asyncTask = new AsyncTask<CharSequence, Integer, ICryptor>() {

            @Override
            protected void onPostExecute(ICryptor result) {
                super.onPostExecute(result);
                progressDialog.dismiss();
                callback.apply(result);
                Log.i(LOG_TAG, "key generation completed in " + (System.currentTimeMillis() - start) + "ms");
            }

            @Override
            protected void onProgressUpdate(Integer... values) {
                super.onProgressUpdate(values);
                progressDialog.setProgress(values[0]);
            }

            @Override
            protected ICryptor doInBackground(CharSequence... params) {
                return Ultracipher.createCryptor(params[0].toString().toCharArray(), KEY_GEN_PERFORMANCE_LEVEL,
                        new IProgressListener() {
                            @Override
                            public boolean currentProgress(float arg0, float arg1) {
                                if (Thread.interrupted()) {
                                    Log.i(LOG_TAG, "terminate key generation");
                                    throw new RuntimeException("Thread interrupted");
                                }
                                publishProgress(Math.round(arg0 / arg1 * 100));
                                return true;
                            }
                        });
            }
        };
        runningTask = asyncTask;
        asyncTask.execute(passphrase);
    }

}
