/*
 * Copyright © 2001,2012 by Paul Burlov. All Rights Reserved.
 * Created May 24, 2012
 */
package de.burlov.ultracipher.core;

import junit.framework.TestCase;

import org.apache.commons.lang3.RandomStringUtils;
import org.junit.Assert;
import org.junit.Test;

import java.util.Random;

public class DatabaseTest extends TestCase {

    public static Database createTestDatabase() {
        Database db = new Database();
        for (int i = 0; i < 10; i++) {
            DataEntry entry = db.addNewEntry();
            entry.setName("name" + i);
            entry.setTags("tags" + i);
            entry.setText("text" + i);
        }
        return db;
    }

    @Test
    public void testSaveLoad() throws Exception {
        Database db = createTestDatabase();
        Random rnd = new Random();
        int i = 0;
        try {
            for (; i < 100; i++) {
                DataEntry e = db.addNewEntry();
                e.setLastChanged(i);
                e.setName(RandomStringUtils.randomAlphanumeric(rnd.nextInt(100) + 1));
                e.setTags(RandomStringUtils.randomAlphanumeric(rnd.nextInt(100) + 1));
                e.setText(RandomStringUtils.randomAlphanumeric(rnd.nextInt(100) + 1));
                String data = db.exportJson();
                String digest = db.computeChecksum();
                Database db2 = new Database();
                db2.importJson(data);
                assertTrue(db2.getEntries().size() > 0);
                assertEquals(db, db2);
                assertEquals(digest, db2.computeChecksum());
            }
        } finally {
            System.out.println("Iterations: " + i);
        }
        String digest = db.computeChecksum();
        DataEntry deletedEntry = db.getEntries().get(0);
        assertTrue(db.getDeletedEntries().isEmpty());
        db.deleteEntry(deletedEntry);
        assertTrue(db.getDeletedEntries().containsKey(deletedEntry.getId()));
        assertFalse(db.getEntryMap().containsKey(deletedEntry.getId()));
        assertFalse(digest.equals(db.computeChecksum()));
        String json = db.exportJson();
        Database db2 = new Database();
        db2.importJson(json);
        assertEquals(db.computeChecksum(), db2.computeChecksum());
        assertTrue(db.getEntries().containsAll(db2.getEntries()));
        assertTrue(db2.getDeletedEntries().containsKey(deletedEntry.getId()));
        assertFalse(db2.getEntryMap().containsKey(deletedEntry.getId()));

        try {
            db2.importJson("");
            Assert.fail("No expected exception was thrown");
        } catch (Exception e) {
            // expected
        }
    }

    @Test
    public void testMerge() throws Exception {
        Database db = new Database();
        DataEntry newEntry = db.addNewEntry();
        newEntry.setName("sadf");
        newEntry.setTags("sdfsdf");
        newEntry.setText("sdfasdf");
        newEntry.setLastChanged(1000);
        String json = db.exportJson();

        Database db2 = new Database();
        String digest1 = db2.computeChecksum();
        assertTrue(db2.getEntries().isEmpty());
        db2.merge(db);
        assertFalse(digest1.equals(db2.computeChecksum()));
        assertEquals(db2.computeChecksum(), db.computeChecksum());
        assertEquals(newEntry, db2.getEntries().get(0));
        db2.importJson(json);
        assertEquals(db2.computeChecksum(), db.computeChecksum());
        assertEquals(db, db2);

        DataEntry newEntry2 = db2.addNewEntry();
        newEntry.setName("sadssf");
        newEntry.setTags("sdf3sdf");
        newEntry.setText("sdf34asdf");
        newEntry.setLastChanged(2000);
        db2.merge(db);
        assertFalse(db.computeChecksum().equals(db2.computeChecksum()));// neue lokale Daten
        assertTrue(db2.getEntries().contains(newEntry2));
        assertFalse(db.getEntries().contains(newEntry2));
        db.merge(db2);
        assertEquals(db2.computeChecksum(), db.computeChecksum());
        assertEquals(db, db2);
    }

    private void assertEquals(Database db1, Database db2) {
        assertTrue(db1.getEntries().containsAll(db2.getEntries()));
        assertTrue(db2.getEntries().containsAll(db1.getEntries()));
    }

    @Test
    public void testMergeDeleted() throws Exception {
        Database db = new Database();
        DataEntry newEntry = db.addNewEntry();
        newEntry.setName("sadf");
        newEntry.setTags("sdfsdf");
        newEntry.setText("sdfasdf");
        newEntry.setLastChanged(1000);

        DataEntry deletedEntry = db.addNewEntry();
        String json = db.exportJson();

        Database db2 = new Database();
        db2.merge(db);
        assertEquals(db.computeChecksum(), db2.computeChecksum());
        assertTrue(db2.getEntries().contains(newEntry));
        assertEquals(db, db2);

        db2.importJson(json);
        db2.deleteEntry(deletedEntry);
        assertFalse(db.computeChecksum().equals(db2.computeChecksum()));
        db2.merge(db);
        assertFalse(db.computeChecksum().equals(db2.computeChecksum()));
        assertFalse(db2.getEntries().contains(deletedEntry));
        db.merge(db2);
        assertTrue(db.computeChecksum().equals(db2.computeChecksum()));
        assertFalse(db.getEntries().contains(deletedEntry));
    }

    @Test
    public void testExportImportCSV() throws Exception {
        Database db = new Database();
        DataEntry newEntry = db.addNewEntry();
        newEntry.setName("sadf");
        newEntry.setTags("sdfsdf");
        newEntry.setText("sdfasdf");
        newEntry.setLastChanged(1000);
        CSVSettings settings = new CSVSettings();
        settings.setDataColumn(0);
        settings.setNameColumn(1);
        settings.setTagsColumn(2);

        String csv = db.exportAsCSV(settings);

        Database db2 = new Database();
        db2.importFromCSV(csv, settings);

        DataEntry en = db2.getEntries().get(0);
        assertEquals(newEntry.getName(), en.getName());
        assertEquals(newEntry.getTags(), en.getTags());
        assertEquals(newEntry.getText(), en.getText());
        assertFalse(newEntry.getId().equals(en.getId()));
    }

}
