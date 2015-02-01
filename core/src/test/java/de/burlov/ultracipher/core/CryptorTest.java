/**
 *
 */
package de.burlov.ultracipher.core;

import org.junit.Assert;
import org.junit.BeforeClass;
import org.junit.Test;

import java.util.Arrays;
import java.util.Random;
import java.util.concurrent.atomic.AtomicInteger;

import de.burlov.ultracipher.core.crypt.SCrypt;

import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

/**
 * Created 08.07.2009
 *
 * @author paul
 *
 */
public class CryptorTest {

    static DeepCascadeCryptor cr = null;

    @BeforeClass
    public static void setup() {
        KeyGenPerformanceLevel level = KeyGenPerformanceLevel.DEFAULT;
        cr = new DeepCascadeCryptor(level.N, level.r, level.p);
        cr.initKey("test".toCharArray(), null);
    }

    @Test
    public void testProgressListener() throws Exception {
        final AtomicInteger progress = new AtomicInteger();
        SCrypt sc = new SCrypt(new IProgressListener() {

            @Override
            public boolean currentProgress(float workDone, float workToDo) {
                System.out.println(workDone + "/" + workToDo);
                assertTrue(workDone <= workToDo);
                if (progress.floatValue() > workDone) {
                    fail("not sequented progress");
                }
                progress.set((int) workDone);
                return true;
            }
        });
        byte[] key = sc.generate("".getBytes("US-ASCII"), "".getBytes("US-ASCII"), 16, 1, 1, 64);
    }

    @Test
    public void testAbortProgress() {
        SCrypt sc = new SCrypt(new IProgressListener() {

            @Override
            public boolean currentProgress(float workDone, float workToDo) {
                return false;
            }
        });
        try {
            sc.generate("".getBytes(), "".getBytes(), 16, 1, 1, 64);
            fail("progress not aborted");
        } catch (Exception e) {
        }
    }

    @Test
    public void testHmac() throws Exception {
        byte[] expectedResult = new byte[]{111, 72, -111, -87, -106, 37, -35, -93, -19, 90, -71, 12, 33, -62, -74, -8, 78, -80, 35, -121};
        //System.out.println(Arrays.toString(cr.hmac("".getBytes("US-ASCII"))));
        Assert.assertArrayEquals(expectedResult, cr.hmac("".getBytes("US-ASCII")));

        expectedResult = new byte[]{62, -59, -103, 99, -125, 15, -28, -126, 30, 42, -16, 65, 70, 85, 33, -113, 3, 34, -71, -60};
        //System.out.println(Arrays.toString(cr.hmac(new byte[0], "Hydrogendioxid".getBytes("UTF-16"), "Tri tra tru la la, der Kasperle ist wieder da".getBytes("UTF-16"))));
        Assert.assertArrayEquals(expectedResult,
                cr.hmac(new byte[0], "Hydrogendioxid".getBytes("UTF-16"), "Tri tra tru la la, der Kasperle ist wieder da".getBytes("UTF-16")));
    }

    @Test
    public void testSCrypt() throws Exception {
        long start = System.currentTimeMillis();
        SCrypt sc = new SCrypt(new IProgressListener() {

            @Override
            public boolean currentProgress(float workDone, float workToDo) {
                System.out.println(workDone + "/" + workToDo);
                return true;
            }
        });
        // Compiler.compileClass(SCrypt.class);
        // Compiler.compileClass(Salsa20Engine.class);
        byte[] key = sc.generate("".getBytes("US-ASCII"), "".getBytes("US-ASCII"), 16, 1, 1, 64);
        byte[] reference = {(byte) 0x77, (byte) 0xd6, (byte) 0x57, (byte) 0x62, (byte) 0x38, (byte) 0x65, (byte) 0x7b, (byte) 0x20, (byte) 0x3b, (byte) 0x19,
                (byte) 0xca, (byte) 0x42, (byte) 0xc1, (byte) 0x8a, (byte) 0x04, (byte) 0x97, (byte) 0xf1, (byte) 0x6b, (byte) 0x48, (byte) 0x44, (byte) 0xe3,
                (byte) 0x07, (byte) 0x4a, (byte) 0xe8, (byte) 0xdf, (byte) 0xdf, (byte) 0xfa, (byte) 0x3f, (byte) 0xed, (byte) 0xe2, (byte) 0x14, (byte) 0x42,
                (byte) 0xfc, (byte) 0xd0, (byte) 0x06, (byte) 0x9d, (byte) 0xed, (byte) 0x09, (byte) 0x48, (byte) 0xf8, (byte) 0x32, (byte) 0x6a, (byte) 0x75,
                (byte) 0x3a, (byte) 0x0f, (byte) 0xc8, (byte) 0x1f, (byte) 0x17, (byte) 0xe8, (byte) 0xd3, (byte) 0xe0, (byte) 0xfb, (byte) 0x2e, (byte) 0x0d,
                (byte) 0x36, (byte) 0x28, (byte) 0xcf, (byte) 0x35, (byte) 0xe2, (byte) 0x0c, (byte) 0x38, (byte) 0xd1, (byte) 0x89, (byte) 0x06};
        Assert.assertTrue(Arrays.equals(key, reference));
        key = sc.generate("password".getBytes("US-ASCII"), "NaCl".getBytes("US-ASCII"), 1024, 8, 16, 64);
        reference = new byte[]{(byte) 0xfd, (byte) 0xba, (byte) 0xbe, (byte) 0x1c, (byte) 0x9d, (byte) 0x34, (byte) 0x72, (byte) 0x00, (byte) 0x78, (byte) 0x56,
                (byte) 0xe7, (byte) 0x19, (byte) 0x0d, (byte) 0x01, (byte) 0xe9, (byte) 0xfe, (byte) 0x7c, (byte) 0x6a, (byte) 0xd7, (byte) 0xcb, (byte) 0xc8,
                (byte) 0x23, (byte) 0x78, (byte) 0x30, (byte) 0xe7, (byte) 0x73, (byte) 0x76, (byte) 0x63, (byte) 0x4b, (byte) 0x37, (byte) 0x31, (byte) 0x62,
                (byte) 0x2e, (byte) 0xaf, (byte) 0x30, (byte) 0xd9, (byte) 0x2e, (byte) 0x22, (byte) 0xa3, (byte) 0x88, (byte) 0x6f, (byte) 0xf1, (byte) 0x09,
                (byte) 0x27, (byte) 0x9d, (byte) 0x98, (byte) 0x30, (byte) 0xda, (byte) 0xc7, (byte) 0x27, (byte) 0xaf, (byte) 0xb9, (byte) 0x4a, (byte) 0x83,
                (byte) 0xee, (byte) 0x6d, (byte) 0x83, (byte) 0x60, (byte) 0xcb, (byte) 0xdf, (byte) 0xa2, (byte) 0xcc, (byte) 0x06, (byte) 0x40};
        Assert.assertTrue(Arrays.equals(key, reference));
        key = sc.generate("pleaseletmein".getBytes("US-ASCII"), "SodiumChloride".getBytes("US-ASCII"), 16384, 8, 1, 64);
        reference = new byte[]{(byte) 0x70, (byte) 0x23, (byte) 0xbd, (byte) 0xcb, (byte) 0x3a, (byte) 0xfd, (byte) 0x73, (byte) 0x48, (byte) 0x46, (byte) 0x1c,
                (byte) 0x06, (byte) 0xcd, (byte) 0x81, (byte) 0xfd, (byte) 0x38, (byte) 0xeb, (byte) 0xfd, (byte) 0xa8, (byte) 0xfb, (byte) 0xba, (byte) 0x90,
                (byte) 0x4f, (byte) 0x8e, (byte) 0x3e, (byte) 0xa9, (byte) 0xb5, (byte) 0x43, (byte) 0xf6, (byte) 0x54, (byte) 0x5d, (byte) 0xa1, (byte) 0xf2,
                (byte) 0xd5, (byte) 0x43, (byte) 0x29, (byte) 0x55, (byte) 0x61, (byte) 0x3f, (byte) 0x0f, (byte) 0xcf, (byte) 0x62, (byte) 0xd4, (byte) 0x97,
                (byte) 0x05, (byte) 0x24, (byte) 0x2a, (byte) 0x9a, (byte) 0xf9, (byte) 0xe6, (byte) 0x1e, (byte) 0x85, (byte) 0xdc, (byte) 0x0d, (byte) 0x65,
                (byte) 0x1e, (byte) 0x40, (byte) 0xdf, (byte) 0xcf, (byte) 0x01, (byte) 0x7b, (byte) 0x45, (byte) 0x57, (byte) 0x58, (byte) 0x87};
        Assert.assertTrue(Arrays.equals(key, reference));
        key = sc.generate("pleaseletmein".getBytes("US-ASCII"), "SodiumChloride".getBytes("US-ASCII"), 1048576, 8, 1, 64);
        reference = new byte[]{(byte) 0x21, (byte) 0x01, (byte) 0xcb, (byte) 0x9b, (byte) 0x6a, (byte) 0x51, (byte) 0x1a, (byte) 0xae, (byte) 0xad, (byte) 0xdb,
                (byte) 0xbe, (byte) 0x09, (byte) 0xcf, (byte) 0x70, (byte) 0xf8, (byte) 0x81, (byte) 0xec, (byte) 0x56, (byte) 0x8d, (byte) 0x57, (byte) 0x4a,
                (byte) 0x2f, (byte) 0xfd, (byte) 0x4d, (byte) 0xab, (byte) 0xe5, (byte) 0xee, (byte) 0x98, (byte) 0x20, (byte) 0xad, (byte) 0xaa, (byte) 0x47,
                (byte) 0x8e, (byte) 0x56, (byte) 0xfd, (byte) 0x8f, (byte) 0x4b, (byte) 0xa5, (byte) 0xd0, (byte) 0x9f, (byte) 0xfa, (byte) 0x1c, (byte) 0x6d,
                (byte) 0x92, (byte) 0x7c, (byte) 0x40, (byte) 0xf4, (byte) 0xc3, (byte) 0x37, (byte) 0x30, (byte) 0x40, (byte) 0x49, (byte) 0xe8, (byte) 0xa9,
                (byte) 0x52, (byte) 0xfb, (byte) 0xcb, (byte) 0xf4, (byte) 0x5c, (byte) 0x6f, (byte) 0xa7, (byte) 0x7a, (byte) 0x41, (byte) 0xa4};
        Assert.assertTrue(Arrays.equals(key, reference));
        System.out.println("SCrypt tests runs in " + (System.currentTimeMillis() - start) + "ms");
    }

    @Test
    public void testRandomSizeBlock() throws Exception {
        long start = System.currentTimeMillis();
        System.out.println("Key generation: " + (System.currentTimeMillis() - start) + "ms");
        start = System.currentTimeMillis();
        Random rnd = new Random();
        long counter = 0;
        for (int i = 0; i < 1000; i++) {
            byte[] plainText = new byte[rnd.nextInt(3000) + 1];
            counter += plainText.length;
            rnd.nextBytes(plainText);
            byte[] cipherText = cr.encrypt(plainText);
            byte[] decyptedText = cr.decrypt(cipherText);
            Assert.assertTrue(Arrays.equals(plainText, decyptedText));
        }
        System.out.println("Enc/Dec " + (counter / 1024) + "KB in " + (System.currentTimeMillis() - start) + "ms");
    }

    @Test
    public void testUndersizeBlock() throws Exception {
        Random rnd = new Random();
        for (int i = 0; i < 10; i++) {
            byte[] plainText = new byte[rnd.nextInt(15) + 1];
            rnd.nextBytes(plainText);
            byte[] cipherText = cr.encrypt(plainText);
            byte[] decyptedText = cr.decrypt(cipherText);
            Assert.assertTrue(Arrays.equals(plainText, decyptedText));
        }
    }

}
