/*
 * Copyright © 2001,2012 by Paul Burlov. All Rights Reserved.
 * Created Jun 6, 2012
 */
package de.burlov.ultracipher.core;

import org.apache.commons.lang3.RandomStringUtils;
import org.junit.BeforeClass;
import org.junit.Ignore;
import org.junit.Test;

import java.io.File;
import java.io.PrintWriter;
import java.util.Random;

import de.burlov.ultracipher.core.Ultracipher.SyncResult;
import de.burlov.ultracipher.core.mail.EmailCredentials;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

public class UltracipherTest {
    static ICryptor cryptor = null;

    @BeforeClass
    static public void setup() {
        cryptor = Ultracipher.createCryptor("test".toCharArray(), KeyGenPerformanceLevel.MIDDLE, null);
    }

    @Test
    public void testSaveLoadAsString() throws Exception {
        Ultracipher uc = new Ultracipher(new PrintWriter(System.out, true));
        uc.setCryptor(cryptor);
        Random rnd = new Random();
        int i = 0;
        try {
            for (; i < 100; i++) {
                Database db = uc.getDatabase();
                DataEntry e = db.addNewEntry();
                e.setLastChanged(i);
                e.setName(RandomStringUtils.randomAlphanumeric(rnd.nextInt(100) + 1));
                e.setTags(RandomStringUtils.randomAlphanumeric(rnd.nextInt(100) + 1));
                e.setText(RandomStringUtils.randomAlphanumeric(rnd.nextInt(100) + 1));
                String data = uc.exportAsPemObject();
                uc.importFromPemObject(data);
                assertTrue(db.getEntries().containsAll(uc.getDatabase().getEntries()));
            }
        } finally {
            System.out.println("Iterations: " + i);
        }
    }

    @Test
    public void testSaveLoad() throws Exception {
        Ultracipher uc = new Ultracipher(new PrintWriter(System.out));
        uc.setCryptor(cryptor);
        //TODO set valid email credentials here
        EmailCredentials creds = new EmailCredentials("email", "psw");
        uc.setSyncCredentials(creds);
        Database db = uc.getDatabase();
        for (int i = 0; i < 10; i++) {
            DataEntry e = db.addNewEntry();
            e.setLastChanged(i);
            e.setName("name" + i);
            e.setTags("tags" + i);
            e.setText("text" + i);
        }
        File temp = File.createTempFile("ultracipher", ".pem");
        uc.saveDatabase(temp);

        {
            uc = new Ultracipher(new PrintWriter(System.out));
            uc.setCryptor(cryptor);
            uc.loadDatabase(temp);
            temp.delete();
            assertTrue(db.getEntries().containsAll(uc.getDatabase().getEntries()));
            assertEquals(creds, uc.getSyncCredentials());
        }
        String data = uc.exportAsPemObject();
        {
            uc = new Ultracipher(new PrintWriter(System.out));
            uc.setCryptor(cryptor);
            uc.importFromPemObject(data);
            assertTrue(db.getEntries().containsAll(uc.getDatabase().getEntries()));
            assertEquals(creds, uc.getSyncCredentials());
        }
    }

    private void testEmailSync(EmailCredentials creds) throws Exception {
        Ultracipher uc = new Ultracipher(new PrintWriter(System.out));
        uc.setCryptor(cryptor);
        uc.setSyncCredentials(creds);
        Random rnd = new Random();
        Database db = uc.getDatabase();
        for (int i = 0; i < 100; i++) {
            DataEntry e = db.addNewEntry();
            e.setLastChanged(i);
            e.setName(RandomStringUtils.randomAlphanumeric(rnd.nextInt(100) + 1));
            e.setTags(RandomStringUtils.randomAlphanumeric(rnd.nextInt(100) + 1));
            e.setText(RandomStringUtils.randomAlphanumeric(rnd.nextInt(100) + 1));
            String data = uc.exportAsPemObject();
            uc.importFromPemObject(data);
            assertTrue(db.getEntries().containsAll(uc.getDatabase().getEntries()));
        }
        uc.save(creds);
        String digest = uc.getDatabase().computeChecksum();
        Thread.currentThread();
        Thread.sleep(1000);

        uc = new Ultracipher(new PrintWriter(System.out));
        uc.setCryptor(cryptor);
        assertTrue(uc.getDatabase().getEntries().isEmpty());
        uc.setSyncCredentials(creds);
        SyncResult syncResult = uc.syncDatabase(true);
        assertEquals(syncResult, SyncResult.IncomingChanges);
        assertEquals(digest, uc.getDatabase().computeChecksum());
        assertTrue(db.getEntries().containsAll(uc.getDatabase().getEntries()));

        syncResult = uc.syncDatabase(true);
        assertEquals(syncResult, SyncResult.NoChanges);
        assertEquals(digest, uc.getDatabase().computeChecksum());
        assertTrue(db.getEntries().containsAll(uc.getDatabase().getEntries()));

        uc.getDatabase().addNewEntry();
        digest = uc.getDatabase().computeChecksum();
        syncResult = uc.syncDatabase(true);
        assertEquals(syncResult, SyncResult.OutgoingChanges);
        assertEquals(digest, uc.getDatabase().computeChecksum());

        ICryptor wrongCryptor = Ultracipher.createCryptor("wrong".toCharArray(), KeyGenPerformanceLevel.DEFAULT, null);
        uc.setCryptor(wrongCryptor);
        syncResult = uc.syncDatabase(true);
        assertEquals(digest, uc.getDatabase().computeChecksum());
        assertEquals(syncResult, SyncResult.NoData);
    }

    @Test
    @Ignore
    public void testMeasurePerformance() {
        System.out.println(Ultracipher.measurePerformance());
        System.out.println(Ultracipher.measurePerformance());
    }
}
