package de.burlov.ultracipher.core;

import org.junit.Assert;
import org.junit.Test;

/**
 * Created by Paul Burlov on 01 Feb 2015.
 */
public class DatabaseContainerTest {
    @Test
    public void testSaveLoad() throws Exception {
        DatabaseContainer container = new DatabaseContainer();
        Database db = new Database();
        DataEntry entry = new DataEntry();
        entry.setName("test");
        entry.setTags("a b c");
        entry.setText("asdfasdf lkjlkjsda lkjsadf");
        db.addNewEntry(entry);


        KeyGenPerformanceLevel level = KeyGenPerformanceLevel.VERY_LOW;
        DeepCascadeCryptor cr = new DeepCascadeCryptor(level.N, level.r, level.p);
        cr.initKey("test".toCharArray(), null);

        container.addNewDatabase(db, cr, "db-name", true);

        String encryptedString = container.saveToString();

        DatabaseContainer loadedContainer = DatabaseContainer.loadFromString(encryptedString);
        Assert.assertEquals(1, loadedContainer.getEntries().size());
        DatabaseContainer.DatabaseEntry loadedEntry = loadedContainer.getEntries().get(0);
        loadedEntry.decrypt(cr);
        Assert.assertEquals("db-name", loadedEntry.name);
        Assert.assertEquals(true, loadedEntry.hidden);
        Assert.assertEquals(db.computeChecksum(), loadedEntry.database.computeChecksum());
    }
}
