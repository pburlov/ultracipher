/*
 * Copyright © 2001,2012 by Paul Burlov. All Rights Reserved.
 * Created Jun 6, 2012
 */
package de.burlov.ultracipher.core;

import org.apache.commons.io.FileUtils;
import org.apache.commons.io.FilenameUtils;
import org.apache.commons.io.filefilter.FileFilterUtils;

import java.io.File;
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.SortedMap;
import java.util.TreeMap;

import de.burlov.ultracipher.core.mail.EmailCredentials;
import de.burlov.ultracipher.core.mail.EmailStore;
import de.burlov.ultracipher.core.mail.SupportedDomain;

/**
 * Kernklasse die High-Level API fuer UI-Clients bereitstell
 *
 * @author paul
 */
public class Ultracipher2 {
    private static final String UTF_8 = "UTF-8";
    static private final String ZIP_ENTRY_EMAIL_CREDENTIALS = "email_account";
    static private final double BASE_PERFORMANCE = 1000;
    static private final String BASE_FILE_NAME = "ultracipher.data";

    static {
    }

    private static final int MAX_DATA_FILES = 100;

    private EmailCredentials syncCredentials;
    private EmailStore emailStore;
    private PrintWriter log;
    private DatabaseContainer databaseContainer = new DatabaseContainer();

    public Ultracipher2(PrintWriter log) {
        super();
        this.log = log;
        emailStore = new EmailStore(log);
    }

    static public double measurePerformance() {
        long start = System.currentTimeMillis();
        ICryptor cryptor = createCryptor("Das ist ein Test".toCharArray(), KeyGenPerformanceLevel.MIDDLE, null);
        byte[] data = new byte[100000];
        cryptor.encrypt(data);
        System.out.println();
        return BASE_PERFORMANCE / (System.currentTimeMillis() - start);
    }

    /**
     * Methode initiaisiert neuen ICryptor Objekt mit der gegebener Passphrase.
     * Operation ist sehr CPU-intensiv
     *
     * @param passphrase
     * @return
     */
    static public ICryptor createCryptor(char[] passphrase, KeyGenPerformanceLevel level, IProgressListener progressListener) {
        DeepCascadeCryptor ret = new DeepCascadeCryptor(level.N, level.r, level.p);
        ret.initKey(passphrase, progressListener);
        return ret;
    }

    /**
     * Methode synchronisiert Daten mit dem eingerichteten Sync-Account. Dh Daten
     * werden vom remote Server gelesen und mit lokalen Daten fusioniert. Falls
     * lokale Aenderungen existieren so muss der Client selbst das Absenden der
     * Daten zu Sync-Account anstossen.
     *
     * @return 'true' wenn lokale Daten mit ankommenden Daten veraendert wurden
     * @throws Exception
     */
    synchronized public SyncResult syncDatabase(boolean deleteSpam) throws Exception {
        if (syncCredentials == null) {
            throw new Exception("Email provider credentials needed");
        }
        if (cryptor == null) {
            throw new Exception("Cryptor not initialized");
        }
        String data = emailStore.loadData(syncCredentials, deleteSpam);
        if (data == null) {
            return SyncResult.NoData;
        }
        EmailCredentials oldCredentials = syncCredentials;
        Database oldDatabase = database;
        String oldLocalDigest = database.computeChecksum();
        importFromPemObjectV1(data);
        String incomingDigest = database.computeChecksum();
        oldDatabase.merge(database);
        database = oldDatabase;
        String newLocalDigest = database.computeChecksum();
        syncCredentials = oldCredentials;
        if (!newLocalDigest.equals(incomingDigest)) {
            return SyncResult.OutgoingChanges;
        }
        if (!oldLocalDigest.equals(newLocalDigest)) {
            return SyncResult.IncomingChanges;
        }
        return SyncResult.NoChanges;
    }

    synchronized public void save(EmailCredentials creds) throws Exception {

        String data = exportAsPemObjectV1();
        emailStore.saveData(creds, data);
    }

    /**
     * Speichert aktuell geladen Datenbank in die angegebene Datei
     *
     * @param destinationDir
     * @throws java.io.IOException
     */
    synchronized public void saveDatabase(File destinationDir) throws Exception {
        FileUtils.forceMkdir(destinationDir);
        File file = findLastDataFile(destinationDir);
        if (file == null) {
            file = new File(destinationDir, BASE_FILE_NAME + ".0");
        } else {
            int version = parseFileVersion(file);
            if (version < 0) version = 0;
            file = new File(destinationDir, BASE_FILE_NAME + "." + (version + 1));
        }
        String data = databaseContainer.saveToString();
        FileUtils.write(file, data, "US-ASCII");
        deleteOutdatedFiles(destinationDir);
    }

    /**
     * Methode loescht stellt sicher, dass maximal eine bestimmte Anzahl an Dateien im Ordner liegt.
     * Die ueberschuessige aeltere Versionen werden geloescht
     *
     * @param dir
     */
    private void deleteOutdatedFiles(File dir) {
        List<File> files = findAllDataFilesSortedByVersionAscending(dir);
        if (files.size() > MAX_DATA_FILES) {
            files = files.subList(0, files.size() - MAX_DATA_FILES);
        }
        for (File f : files) {
            log.print("Delete " + f.getAbsolutePath());
            if (!f.delete()) {
                log.println(" failed");
            } else {
                log.println();
            }
        }
    }

    List<File> findAllDataFilesSortedByVersionAscending(File dir) {
        if (!dir.exists() || dir.isDirectory()) return Collections.emptyList();
        SortedMap<Integer, File> map = new TreeMap<>();
        for (File f : FileUtils.listFiles(dir, FileFilterUtils.prefixFileFilter(BASE_FILE_NAME), FileFilterUtils.falseFileFilter())) {
            int version = parseFileVersion(f);
            if (version > -1) {
                map.put(version, f);
            }
        }
        return new ArrayList<>(map.values());
    }

    /**
     * Findet Datenbankdatei mit der hoechster Versionsnummer
     * @param dir Verzeichnis wo gesucht weden soll
     * @return die gefundene Datei oder null
     */
    File findLastDataFile(File dir) {
        List<File> files = findAllDataFilesSortedByVersionAscending(dir);
        if (files.isEmpty()) return null;
        return files.get(files.size() - 1);
    }

    /**
     *
     * @param file
     * @return -1 wenn die Versionsnummer nicht geparst werden kann
     */
    int parseFileVersion(File file) {
        try {
            return Integer.parseInt(FilenameUtils.getExtension(file.getName()));
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    /**
     * Laedt Datenbank von der gegebener Datei
     *
     * @param source
     * @throws java.io.IOException
     */
    synchronized public void loadDatabase(File source) throws Exception {
        String data = FileUtils.readFileToString(source, "US-ASCII");
        databaseContainer = DatabaseContainer.loadFromString(data);
    }

    public EmailCredentials getSyncCredentials() {
        return syncCredentials;
    }

    public void setSyncCredentials(EmailCredentials syncCredentials) {
        this.syncCredentials = syncCredentials;
    }

    public List<SupportedDomain> getSupportedEmailSyncDomains() {
        return emailStore.getSupportedMailDomains();
    }

    public enum SyncResult {
        /**
         * Daten wurden downgeladet, aber keine Aenderungen gegenueber lokalen Daten
         */
        NoChanges,
        /**
         * Daten wurden runtergeladen und es wurden Aenderungen an lokalen Daten
         * durchgefuehrt
         */
        IncomingChanges,
        /**
         * Lokale Daten sind aktueller als runtergeladene Daten
         */
        OutgoingChanges,
        /**
         * Keine Daten wurden auf dem Server gefunden
         */
        NoData
    }

}
