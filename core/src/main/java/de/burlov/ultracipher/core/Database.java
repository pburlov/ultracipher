/*
 	Copyright (C) 2009 Paul Burlov
 	
 	
    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */
package de.burlov.ultracipher.core;

import org.apache.commons.lang3.StringUtils;
import org.json.simple.JSONArray;
import org.json.simple.JSONValue;

import java.io.DataOutputStream;
import java.io.IOException;
import java.io.StringReader;
import java.io.StringWriter;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Map.Entry;
import java.util.TreeMap;
import java.util.UUID;

import au.com.bytecode.opencsv.CSVReader;
import au.com.bytecode.opencsv.CSVWriter;
import de.burlov.ultracipher.core.bouncycastle.crypto.digests.RIPEMD160Digest;
import de.burlov.ultracipher.core.bouncycastle.crypto.io.DigestOutputStream;
import de.burlov.ultracipher.core.bouncycastle.util.encoders.Hex;

/**
 * Dataholder of entire database data
 * <p/>
 * Created 05.03.2009
 *
 * @author paul
 */
public class Database {
    // Definiert wie lange Information ueber geloeschte Eintraege gehalten wird
    private static final long DELETE_ENTRIES_TTL = 1000 * 60 * 60 * 24 * 300;
    private static final String CHANGED = "changed";
    private static final String ID = "id";
    private static final String TEXT = "text";
    private static final String TAGS = "tags";
    private static final String NAME = "name";
    private TreeMap<String, DataEntry> entries = new TreeMap<String, DataEntry>();
    private TreeMap<String, Long> deletedEntries = new TreeMap<String, Long>();

    public Database() {
        super();
    }

    public String computeChecksum() {
        DigestOutputStream digest = new DigestOutputStream(new RIPEMD160Digest());
        DataOutputStream out = new DataOutputStream(digest);

        try {
            for (Entry<String, Long> entry : deletedEntries.entrySet()) {
                out.writeUTF(entry.getKey());
                out.writeLong(entry.getValue());
            }
            for (DataEntry entry : entries.values()) {
                out.writeUTF(entry.getId());
                out.writeUTF(entry.getName());
                out.writeUTF(entry.getTags());
                out.writeUTF(entry.getText());
            }
            out.close();
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
        return new String(Hex.encode(digest.getDigest()));
    }

    public void clear() {
        entries.clear();
        deletedEntries.clear();
    }

    public void deleteEntry(DataEntry entry) {
        entries.remove(entry.getId());
        deletedEntries.put(entry.getId(), System.currentTimeMillis());
    }

    /**
     * Fuehgt neuen Eintrag zu.
     *
     * @param template Daten um den neuen Eintrag zu fuellen
     * @return
     */
    public DataEntry addNewEntry(DataEntry template) {
        DataEntry ret = addNewEntry();
        ret.setName(template.getName());
        ret.setTags(template.getTags());
        ret.setText(template.getText());
        return ret;
    }

    /**
     * Fuegt neuen Eintrag
     *
     * @return neues Datenobjekt
     */
    public DataEntry addNewEntry() {
        DataEntry ret = new DataEntry(UUID.randomUUID().toString());
        ret.setLastChanged(System.currentTimeMillis());
        entries.put(ret.getId(), ret);
        deletedEntries.remove(ret.getId());
        return ret;
    }

    public List<DataEntry> getEntries() {
        return new ArrayList<DataEntry>(entries.values());
    }

    /**
     * @return Copy der interner Map
     */
    public Map<String, DataEntry> getEntryMap() {
        return new HashMap<String, DataEntry>(entries);
    }

    /**
     * Methode fuehrt Entraege von aktueller und gegebener Datenbank zusammen.
     *
     * @param db
     * @return 'true' wenn Daten durch gegebene Daten geaendert wurden
     */
    public void merge(Database db) {
        deletedEntries.putAll(db.getDeletedEntries());
        for (Entry<String, DataEntry> entry : db.entries.entrySet()) {
            if (deletedEntries.containsKey(entry.getKey())) {
                // Datensatz als geloescht markiert und soll verworfen werden
                continue;
            }
            DataEntry lokalEntry = this.entries.get(entry.getKey());
            if (lokalEntry == null) {
                /*
                 * Keine lokalen Datensatz mit dieser ID
				 */
                this.entries.put(entry.getKey(), entry.getValue());
                continue;
            }
            if (lokalEntry.getLastChanged() < entry.getValue().getLastChanged()) {
				/*
				 * Lokaler Datensatz ist aelter und wird durch aktuelleren
				 * ersetzt
				 */
                this.entries.put(entry.getKey(), entry.getValue());
            }
        }
		/*
		 * Jetzt als geloescht markierte lokale Datensaetze finden und loeschen
		 */
        for (DataEntry de : getEntries()) {
            if (deletedEntries.containsKey(de.getId())) {
                this.entries.remove(de.getId());
            }
        }
    }

    /**
     * Laedt Daten aus dem JSON String
     *
     * @param json
     * @throws Exception
     */
    public void importJson(String json) throws Exception {
        TreeMap<String, DataEntry> newEntries = new TreeMap<String, DataEntry>();
        List rootArray = (List) JSONValue.parse(json);
        /*
		 * Primaere Daten laden
		 */
        List array = (List) rootArray.get(0);
        for (int i = 0; i < array.size(); i++) {
            Map o = (Map) array.get(i);
            DataEntry e = new DataEntry((String) o.get(ID));
            e.setLastChanged(((Number) o.get(CHANGED)).longValue());
            e.setName((String) o.get(NAME));
            e.setTags((String) o.get(TAGS));
            e.setText((String) o.get(TEXT));

            newEntries.put(e.getId(), e);
        }
		/*
		 * Ids der geloeschten Elemente laden
		 */
        array = (List) rootArray.get(1);
        TreeMap<String, Long> deletedMap = new TreeMap<String, Long>();
        for (int i = 0; i < array.size(); i++) {
            List arr = (List) array.get(i);
            String id = (String) arr.get(0);
            Long time = ((Number) arr.get(1)).longValue();
            deletedMap.put(id, time);
        }
        this.entries = newEntries;
        this.deletedEntries = deletedMap;
    }

    /**
     * @return Daten als JSON String
     * @throws Exception
     */
    public String exportJson() throws Exception {
        JSONArray rootArray = new JSONArray();
        /*
		 * Primaere Daten schreiben
		 */
        List jsonEntries = new ArrayList<>();
        rootArray.add(jsonEntries);
        for (DataEntry entry : entries.values()) {
            Map map = new HashMap();
            jsonEntries.add(map);
            map.put(ID, entry.getId());
            map.put(CHANGED, entry.getLastChanged());
            map.put(NAME, entry.getName());
            map.put(TAGS, entry.getTags());
            map.put(TEXT, entry.getText());
        }
		/*
		 * Liste mit IDs der geloeschte Elemente schreiben
		 */
        jsonEntries = new ArrayList<>();
        rootArray.add(jsonEntries);
        long thresholdTime = System.currentTimeMillis() - DELETE_ENTRIES_TTL;
        for (Entry<String, Long> entry : deletedEntries.entrySet()) {
            if (entry.getValue() < thresholdTime) {
                // abgelaufene Eintraege gar nicht abspeichern
                continue;
            }
            jsonEntries.add(Arrays.asList(entry.getKey(), entry.getValue()));
        }
        return rootArray.toJSONString();
    }

    public Map<String, Long> getDeletedEntries() {
        return deletedEntries;
    }

    public void importFromCSV(String csv, CSVSettings settings) {
        if (StringUtils.isBlank(csv)) {
            return;
        }
        CSVReader reader = new CSVReader(new StringReader(csv), settings.getSeparator(), settings.getQuoteChar());
        while (true) {
            String[] line = null;
            try {
                line = reader.readNext();
            } catch (IOException e) {
                // Kann eigentlich nie auftreten
                e.printStackTrace();
                return;
            }
            if (line == null) {
                break;
            }
            DataEntry entry = addNewEntry();
            if (line.length > settings.getNameColumn()) {
                entry.setName(line[settings.getNameColumn()]);
            }
            if (line.length > settings.getTagsColumn()) {
                entry.setTags(line[settings.getTagsColumn()]);
            }
            if (line.length > settings.getDataColumn()) {
                entry.setText(line[settings.getDataColumn()]);
            }
        }
    }

    public String exportAsCSV(CSVSettings settings) {
        StringWriter swriter = new StringWriter();
        CSVWriter writer = new CSVWriter(swriter, settings.getSeparator(), settings.getQuoteChar(),
                settings.getQuoteChar(), settings.getLineEnd());
        String[] line = new String[Math.max(settings.getDataColumn(),
                Math.max(settings.getNameColumn(), Math.max(settings.getTagsColumn(), 0))) + 1];
        for (DataEntry entry : getEntries()) {
            line[settings.getNameColumn()] = entry.getName();
            line[settings.getTagsColumn()] = entry.getTags();
            line[settings.getDataColumn()] = entry.getText();
            for (int i = 0; i < line.length; i++) {
                if (line[i] == null) {
                    line[i] = "";
                }
            }
            writer.writeNext(line);
        }
        try {
            writer.flush();
            writer.close();
        } catch (IOException e) {
            // kann nie auftreten
            e.printStackTrace();
        }
        return swriter.toString();
    }

}
