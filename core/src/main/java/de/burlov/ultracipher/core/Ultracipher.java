/*
 * Copyright © 2001,2012 by Paul Burlov. All Rights Reserved.
 * Created Jun 6, 2012
 */
package de.burlov.ultracipher.core;

import org.apache.commons.io.FileUtils;
import org.apache.commons.io.IOUtils;
import org.apache.commons.lang3.StringUtils;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.io.StringReader;
import java.io.StringWriter;
import java.util.Arrays;
import java.util.List;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import java.util.zip.ZipOutputStream;

import de.burlov.ultracipher.core.bouncycastle.util.io.pem.PemGenerationException;
import de.burlov.ultracipher.core.bouncycastle.util.io.pem.PemObject;
import de.burlov.ultracipher.core.bouncycastle.util.io.pem.PemObjectGenerator;
import de.burlov.ultracipher.core.bouncycastle.util.io.pem.PemReader;
import de.burlov.ultracipher.core.bouncycastle.util.io.pem.PemWriter;
import de.burlov.ultracipher.core.json.JSONException;
import de.burlov.ultracipher.core.mail.EmailCredentials;
import de.burlov.ultracipher.core.mail.EmailStore;
import de.burlov.ultracipher.core.mail.SupportedDomain;

/**
 * Kernklasse die High-Level API fuer UI-Clients bereitstell
 *
 * @author paul
 */
public class Ultracipher {
    private static final String UTF_8 = "UTF-8";
    private static final String PEM_TYPE = "UltraCipher_v1";
    static private final String ZIP_ENTRY_DATA = "data";
    static private final String ZIP_ENTRY_EMAIL_CREDENTIALS = "email_account";
    static private final double BASE_PERFORMANCE = 1000;

    static {
    }

    private ICryptor cryptor;
    private Database database = new Database();
    private EmailCredentials syncCredentials;
    private EmailStore emailStore;
    private PrintWriter log;

    public Ultracipher(PrintWriter log) {
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
        String data = emailStore.loadData(syncCredentials, deleteSpam, getCurrentCryptor());
        if (data == null) {
            return SyncResult.NoData;
        }
        EmailCredentials oldCredentials = syncCredentials;
        Database oldDatabase = database;
        String oldLocalDigest = database.computeChecksum();
        importFromPemObject(data);
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
        String data = exportAsPemObject();
        emailStore.saveData(creds, data, getCurrentCryptor());
    }

    /**
     * Speichert aktuell geladen Datenbank in die angegebene Datei
     *
     * @param destination
     * @throws java.io.IOException
     */
    synchronized public void saveDatabase(File destination) throws Exception {
        OutputStream out = FileUtils.openOutputStream(destination);
        try {
            String data = exportAsPemObject();
            IOUtils.write(data, out, "US-ASCII");
        } finally {
            IOUtils.closeQuietly(out);
        }
    }

    synchronized public String exportAsPemObject() throws Exception {
        if (cryptor == null) {
            throw new Exception("Cryptor not initialized");
        }
        ByteArrayOutputStream bout = new ByteArrayOutputStream();
        ZipOutputStream zout = new ZipOutputStream(bout);
        byte[] plainData = database.exportJson().getBytes(UTF_8);
        ZipEntry zipEntry = new ZipEntry(ZIP_ENTRY_DATA);
        zipEntry.setSize(plainData.length);
        zout.putNextEntry(zipEntry);
        zout.write(plainData);
        Arrays.fill(plainData, (byte) 0);
        zout.closeEntry();
        if (syncCredentials != null) {
            zipEntry = new ZipEntry(ZIP_ENTRY_EMAIL_CREDENTIALS);
            plainData = syncCredentials.exportJson().getBytes(UTF_8);
            zipEntry.setSize(plainData.length);
            zout.putNextEntry(zipEntry);
            zout.write(plainData);
            zout.closeEntry();
        }
        zout.close();
        plainData = bout.toByteArray();
        final byte[] encryptedData = cryptor.encrypt(plainData);
        Arrays.fill(plainData, (byte) 0);
        StringWriter sWriter = new StringWriter();
        PemWriter pemWriter = new PemWriter(sWriter);
        pemWriter.writeObject(new PemObjectGenerator() {

            @Override
            public PemObject generate() throws PemGenerationException {
                return new PemObject(PEM_TYPE, encryptedData);
            }
        });
        pemWriter.close();
        return sWriter.toString();
    }

    synchronized public void importFromPemObject(String data) throws Exception {
        if (cryptor == null) {
            throw new Exception("Cryptor not initialized");
        }
        PemReader pemReader = new PemReader(new StringReader(data));
        PemObject pemObject = pemReader.readPemObject();
        if (pemObject == null || pemObject.getContent().length == 0 || !PEM_TYPE.equals(pemObject.getType())) {
            throw new Exception("Invalid file");
        }
        byte[] encryptedData = pemObject.getContent();
        byte[] plainData = cryptor.decrypt(encryptedData);
        ZipInputStream zin = new ZipInputStream(new ByteArrayInputStream(plainData));
        ZipEntry zipEntry = null;
        Database loadedDb = null;
        EmailCredentials loadedCreds = null;
        while ((zipEntry = zin.getNextEntry()) != null) {
            if (StringUtils.equals(ZIP_ENTRY_DATA, zipEntry.getName())) {
                Database db = new Database();
                db.importJson(IOUtils.toString(zin, UTF_8));
                loadedDb = db;
            }
            if (StringUtils.equalsIgnoreCase(ZIP_ENTRY_EMAIL_CREDENTIALS, zipEntry.getName())) {
                try {
                    loadedCreds = EmailCredentials.importJson(IOUtils.toString(zin, UTF_8));
                } catch (JSONException e) {
                    log.println(e.toString());
                }
            }
        }
        Arrays.fill(plainData, (byte) 0);
        /*
         * Keine Datenbank gefunden
		 */
        if (loadedDb == null) {
            throw new Exception("Invalid file or wrong passphrase");
        }
        database = loadedDb;
        if (loadedCreds != null) {
            syncCredentials = loadedCreds;
        }
    }

    /**
     * Laedt Datenbank von der gegebener Datei
     *
     * @param source
     * @throws java.io.IOException
     */
    synchronized public void loadDatabase(File source) throws Exception {
        InputStream in = FileUtils.openInputStream(source);
        try {
            importFromPemObject(IOUtils.toString(in, "US-ASCII"));
        } finally {
            IOUtils.closeQuietly(in);
        }
    }

    /**
     * Setzt ICryptor-Objekt fuer alle nachfolgende load/save/sync Operationen
     *
     * @param cryptor
     */
    public void setCryptor(ICryptor cryptor) {
        this.cryptor = cryptor;
    }

    /**
     * @return aktuell aktiven ICryptor. kann null sein
     */
    public ICryptor getCurrentCryptor() {
        return this.cryptor;
    }

    /**
     * @return aktuell geladene Datenbank, niemals null
     */
    public Database getDatabase() {
        return this.database;
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

    public void importFromCSV(String csv, CSVSettings settings) {
        database.importFromCSV(csv, settings);
    }

    public String exportAsCSV(CSVSettings settings) {
        return database.exportAsCSV(settings);
    }

    public void clear() {
        if (cryptor != null) {
            cryptor.clear();
            cryptor = null;
        }
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
