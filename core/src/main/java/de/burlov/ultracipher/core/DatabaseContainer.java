package de.burlov.ultracipher.core;

import org.apache.commons.io.IOUtils;
import org.json.simple.JSONArray;
import org.json.simple.JSONObject;
import org.json.simple.JSONValue;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.StringReader;
import java.io.StringWriter;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.zip.GZIPInputStream;
import java.util.zip.GZIPOutputStream;

import de.burlov.ultracipher.core.bouncycastle.util.io.pem.PemObject;
import de.burlov.ultracipher.core.bouncycastle.util.io.pem.PemReader;
import de.burlov.ultracipher.core.bouncycastle.util.io.pem.PemWriter;

/**
 * Created by Paul Burlov on 01.02.2015.
 */
public class DatabaseContainer {
    public static final String UTF_8 = "UTF-8";
    private static final String PEM_TYPE = "UltraCipher_v2";
    private List<DatabaseEntry> entries = new ArrayList<>();

    public static DatabaseContainer loadFromString(String data) throws Exception {
        DatabaseContainer databaseContainer = new DatabaseContainer();
        PemReader pemReader = new PemReader(new StringReader(data));
        PemObject pemObject = pemReader.readPemObject();
        if (pemObject == null || pemObject.getContent().length == 0 || !PEM_TYPE.equals(pemObject.getType())) {
            throw new IOException("Invalid file");
        }
        String content = new String(pemObject.getContent(), UTF_8);
        Map jo = (Map) JSONValue.parse(content);
        List ja = (List) jo.get("entries");
        for (int i = 0; i < ja.size(); i++) {
            Map o = (Map) ja.get(i);
            DatabaseEntry dbe = DatabaseEntry.loadFromJson(o);
            databaseContainer.entries.add(dbe);
        }
        return databaseContainer;
    }

    public String saveToString() throws Exception {
        JSONObject jo = new JSONObject();
        JSONArray ja = new JSONArray();
        jo.put("entries", ja);
        for (DatabaseEntry entry : entries) {
            ja.add(entry.saveToJson());
        }
        byte[] bytes = jo.toString().getBytes(UTF_8);
        StringWriter sw = new StringWriter();
        PemWriter pemWriter = new PemWriter(sw);
        PemObject pemObject = new PemObject(PEM_TYPE, bytes);
        pemWriter.writeObject(pemObject);
        pemWriter.close();
        return sw.toString();
    }

    public void addNewDatabase(Database database, ICryptor cryptor, String name, boolean hidden) {
        assert database != null;
        assert cryptor != null;
        DatabaseEntry databaseEntry = new DatabaseEntry(null);
        databaseEntry.cryptor = cryptor;
        databaseEntry.database = database;
        databaseEntry.name = name;
        databaseEntry.hidden = hidden;
        entries.add(databaseEntry);
    }

    public List<DatabaseEntry> getEntries() {
        return new ArrayList(entries);
    }

    public void deleteEntry(DatabaseEntry entry) {
        entries.remove(entry);
    }

    public static class DatabaseEntry {
        final String rawData;
        boolean hidden = false;
        String name;
        ICryptor cryptor;
        Database database;
        Map<String, String> cryptorParams;

        private DatabaseEntry(String rawData) {
            this.rawData = rawData;
        }

        static DatabaseEntry loadFromJson(Map jo) {
            DatabaseEntry dbe = new DatabaseEntry((String) jo.get("data"));
            dbe.name = (String) jo.get("name");
            dbe.hidden = (Boolean) jo.get("hidden");
            dbe.cryptorParams = (Map<String, String>) jo.get("cryptor-params");
            return dbe;
        }

        JSONObject saveToJson() throws Exception {
            String encryptedString = rawData;
            if (cryptor != null && database != null) {
                ByteArrayOutputStream bout = new ByteArrayOutputStream();
                GZIPOutputStream gzipOut = new GZIPOutputStream(bout);
                byte[] data = database.exportJson().getBytes(UTF_8);
                gzipOut.write(data);
                gzipOut.close();
                data = bout.toByteArray();
                byte[] encryptedData = cryptor.encrypt(data);
                //Unverschluesselte Daten aus dem RAM loeschen
                Arrays.fill(data, (byte) 0);
                StringWriter stringWriter = new StringWriter();
                PemWriter pw = new PemWriter(stringWriter);
                PemObject po = new PemObject("data", encryptedData);
                pw.writeObject(po);
                pw.close();
                encryptedString = stringWriter.toString();
            }
            JSONObject jo = new JSONObject();
            jo.put("data", encryptedString);
            jo.put("name", name);
            jo.put("hidden", hidden);
            jo.put("cryptor-params", cryptor.getParameters());
            return jo;
        }

        public void decrypt(ICryptor cryptor) throws Exception {
            PemReader pr = new PemReader(new StringReader(rawData));
            PemObject pemObject = pr.readPemObject();
            byte[] encryptedContent = pemObject.getContent();
            byte[] plainContent = cryptor.decrypt(encryptedContent);
            GZIPInputStream gzipIn = new GZIPInputStream(new ByteArrayInputStream(plainContent));
            ByteArrayOutputStream bout = new ByteArrayOutputStream();
            IOUtils.copy(gzipIn, bout);
            Arrays.fill(plainContent, (byte) 0);
            plainContent = bout.toByteArray();
            Database db = new Database();
            db.importJson(new String(plainContent, UTF_8));
            this.database = db;
            this.cryptor = cryptor;
        }

    }
}
