/**
 Copyright (C) 2012 Paul Burlov

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

import java.io.UnsupportedEncodingException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Random;

import de.burlov.ultracipher.core.bouncycastle.crypto.BlockCipher;
import de.burlov.ultracipher.core.bouncycastle.crypto.DataLengthException;
import de.burlov.ultracipher.core.bouncycastle.crypto.PBEParametersGenerator;
import de.burlov.ultracipher.core.bouncycastle.crypto.digests.RIPEMD160Digest;
import de.burlov.ultracipher.core.bouncycastle.crypto.engines.AESEngine;
import de.burlov.ultracipher.core.bouncycastle.crypto.engines.CAST6Engine;
import de.burlov.ultracipher.core.bouncycastle.crypto.engines.CamelliaEngine;
import de.burlov.ultracipher.core.bouncycastle.crypto.engines.SEEDEngine;
import de.burlov.ultracipher.core.bouncycastle.crypto.engines.SerpentEngine;
import de.burlov.ultracipher.core.bouncycastle.crypto.engines.TwofishEngine;
import de.burlov.ultracipher.core.bouncycastle.crypto.modes.CBCBlockCipher;
import de.burlov.ultracipher.core.bouncycastle.crypto.params.KeyParameter;
import de.burlov.ultracipher.core.bouncycastle.crypto.params.ParametersWithIV;
import de.burlov.ultracipher.core.bouncycastle.crypto.util.Pack;
import de.burlov.ultracipher.core.crypt.SCrypt;

/**
 * Verarbeitet Daten mit einem Stack aus Ciphers. D.h. jedes Block wird
 * nacheinander durch mehrere Ciphers verarbeitet bis der naechste Block dran
 * ist. Als Cipher-Mode wird CBC verwendet.
 * <p/>
 * Created 28.5.2012
 *
 * @author paul
 */
public class DeepCascadeCryptor implements ICryptor {
    private static final byte[] DEFAULT_SALT;
    private static final int BLOCK_SIZE_BYTES = 16;
    private static final int KEY_SIZE_BYTES = 16;

    static {
        try {
            DEFAULT_SALT = "CryptorV2".getBytes("US-ASCII");
        } catch (UnsupportedEncodingException e) {
            throw new RuntimeException(e);
        }
    }

    private int N = 16384;
    private int r = 8;
    private int p = 1;
    private List<BlockCipher> ciphers = new ArrayList<BlockCipher>();
    private List<KeyParameter> keys = new ArrayList<KeyParameter>();

    public DeepCascadeCryptor(int n, int r, int p) {
        super();
        N = n;
        this.r = r;
        this.p = p;
        /*
         * Alle Ciphers sollen gleiche Block size: 128Bit und Key Size: 128Bit
		 * benutzen
		 */
        ciphers.add(new AESEngine());
        ciphers.add(new TwofishEngine());
        ciphers.add(new SerpentEngine());
        ciphers.add(new CAST6Engine());
        ciphers.add(new SEEDEngine());
        ciphers.add(new CamelliaEngine());
    }

    public void initKey(byte[] primaryKey) {
        if (primaryKey.length < ciphers.size() * KEY_SIZE_BYTES) {
            throw new IllegalArgumentException("too short primary key");
        }
        for (int i = 0; i < ciphers.size(); i++) {
            keys.add(new KeyParameter(primaryKey, i * KEY_SIZE_BYTES, KEY_SIZE_BYTES));
        }
        if (keys.size() < ciphers.size()) {
            throw new IllegalStateException("Not enough keys: " + keys.size());
        }
		/*
		 * Nicht benoetigte Schluesseldaten umgehend loeschen
		 */
        Arrays.fill(primaryKey, (byte) 0);
    }

    public void initKey(char[] passphrase, IProgressListener progressListener) {
        SCrypt sc = new SCrypt(progressListener);
        byte[] primaryKey = sc.generate(PBEParametersGenerator.PKCS5PasswordToUTF8Bytes(passphrase), DEFAULT_SALT, N, r, p, getNeededKeyLengthBytes());
        initKey(primaryKey);
    }

    public int getNeededKeyLengthBytes() {
        return ciphers.size() * KEY_SIZE_BYTES;
    }

    private BlockCipher initCiphers(boolean forEncryption) {
        if (keys.size() < ciphers.size()) {
            throw new IllegalStateException("Not enough keys: " + keys.size());
        }
        for (int i = 0; i < ciphers.size(); i++) {
            BlockCipher c = ciphers.get(i);
            KeyParameter key = keys.get(i);
            c.init(forEncryption, key);
        }
        List<BlockCipher> sortedCiphers = ciphers;
        if (!forEncryption) {
            sortedCiphers = new ArrayList<BlockCipher>(ciphers);
            Collections.reverse(sortedCiphers);
        }
        CascadeCipher cascade = new CascadeCipher(BLOCK_SIZE_BYTES, sortedCiphers);
        BlockCipher ret = new CBCBlockCipher(cascade);
        return ret;
    }

    /*
     * (non-Javadoc)
     *
     * @see de.b.crypto.ICryptor#decrypt(byte[])
     */
    @Override
    public byte[] decrypt(byte[] cipherText) throws Exception {
        // Minimale Laenge des Input-Arrays: Header, Laenge des Plaintextes, IV
        // und mindestens ein Block Ciphertextes
        int requiredLength = 4 + BLOCK_SIZE_BYTES + BLOCK_SIZE_BYTES;
        if (cipherText.length < requiredLength) {
            throw new DataLengthException("Too short input array: " + cipherText.length + " required: " + requiredLength);
        }
        int plaintextLength = Pack.bigEndianToInt(cipherText, 0);
        int offset = 4;
        int ivOffset = offset;
		/*
		 * 1. Runde
		 */
        BlockCipher decCipher = initCiphers(false);
        decCipher.init(false, new ParametersWithIV(null, cipherText, ivOffset, BLOCK_SIZE_BYTES));
        offset += BLOCK_SIZE_BYTES;
        byte[] out1 = new byte[cipherText.length - offset];
        processDataBackwards(cipherText, offset, out1, 0, out1.length, decCipher);

		/*
		 * 2. Runde
		 */
        decCipher = initCiphers(false);
        decCipher.init(false, new ParametersWithIV(null, cipherText, ivOffset, BLOCK_SIZE_BYTES));
        byte[] out2 = new byte[cipherText.length - offset];
        processDataForwards(out1, 0, out2, 0, out2.length, decCipher);

        byte[] plainText = new byte[plaintextLength];
        System.arraycopy(out2, 0, plainText, 0, plaintextLength);
        Arrays.fill(out1, (byte) 0);
        Arrays.fill(out2, (byte) 0);
        return plainText;
    }

    /**
     * Methode erweitert input byte Array zu Block-gerader Laenge
     *
     * @param input
     * @return neue Byte Array
     */
    private byte[] alignToBlockSize(byte[] input) {
        byte[] ret = new byte[input.length + (BLOCK_SIZE_BYTES - (input.length % BLOCK_SIZE_BYTES))];
        System.arraycopy(input, 0, ret, 0, input.length);
        return ret;
    }

    /**
     * Prozessiert Daten von vorne nach hinten blockweise
     *
     * @param in
     * @param inOffset
     * @param length
     * @param out
     * @param cipher
     */
    private void processDataForwards(byte[] in, int inOffset, byte[] out, int outOffset, int length, BlockCipher cipher) {
        for (int i = 0; i < length; i = i + BLOCK_SIZE_BYTES) {
            cipher.processBlock(in, i + inOffset, out, i + outOffset);
        }
    }

    /**
     * Prozessiert Daten von hinten nach vorne blockweise
     *
     * @param in
     * @param inOffset
     * @param length
     * @param out
     * @param cipher
     */
    private void processDataBackwards(byte[] in, int inOffset, byte[] out, int outOffset, int length, BlockCipher cipher) {
        for (int i = length - BLOCK_SIZE_BYTES; i >= 0; i = i - BLOCK_SIZE_BYTES) {
            cipher.processBlock(in, i + inOffset, out, i + outOffset);
        }
    }

    /*
     * (non-Javadoc)
     *
     * @see de.b.crypto.ICryptor#encrypt(byte[])
     */
    @Override
    public byte[] encrypt(final byte[] plainText) {
        byte[] iv = new byte[BLOCK_SIZE_BYTES];
        new Random().nextBytes(iv);
        return encrypt(plainText, iv);
    }

    private byte[] encrypt(final byte[] plainText, byte[] iv) {
        byte[] alignedPlainText = alignToBlockSize(plainText);
        byte[] buffer = new byte[alignedPlainText.length];

        BlockCipher encCipher = initCiphers(true);
		/*
		 * Unterliegende CipherEngines sind schon initialisiert. Das KeyParameter
		 * Objekt ist ein dummy damit CBCMode nicht meckert
		 */
        encCipher.init(true, new ParametersWithIV(new KeyParameter(DEFAULT_SALT), iv));
        processDataForwards(alignedPlainText, 0, buffer, 0, alignedPlainText.length, encCipher);

		/*
		 * Ausreichend Platz fuer Header, IV, Laenge des Plaintextes und CipherText
		 * selbst
		 */
        byte[] result = new byte[alignedPlainText.length + iv.length + 4];
        int offset = 0;
        Pack.intToBigEndian(plainText.length, result, offset);
        offset += 4;
        System.arraycopy(iv, 0, result, offset, iv.length);
        offset += iv.length;

        encCipher = initCiphers(true);
		/*
		 * Unterliegende CipherEngines sind schon initialisiert. Das KeyParameter
		 * Objekt ist ein dummy damit CBCMode nicht meckert
		 */
        encCipher.init(true, new ParametersWithIV(new KeyParameter(DEFAULT_SALT), iv));
        processDataBackwards(buffer, 0, result, offset, buffer.length, encCipher);
        Arrays.fill(alignedPlainText, (byte) 0);
        Arrays.fill(buffer, (byte) 0);
        return result;
    }

    @Override
    protected void finalize() throws Throwable {
		/*
		 * Schluesseldaten und temporaere Daten loeschen
		 */
        // Arrays.fill(processBuffer, (byte) 0);
        for (KeyParameter key : keys) {
            Arrays.fill(key.getKey(), (byte) 0);
        }
    }

    @Override
    public byte[] hmac(byte[]... data) {
        byte[] concatedData = alignToBlockSize(concate(data));
        byte[] encryptedData = encrypt(concatedData, new byte[BLOCK_SIZE_BYTES]);
        RIPEMD160Digest digest = new RIPEMD160Digest();
        digest.update(encryptedData, 0, encryptedData.length);
        byte[] ret = new byte[digest.getDigestSize()];
        digest.doFinal(ret, 0);
        return ret;
    }

    private byte[] concate(byte[]... arrays) {
        int length = 0;
        for (byte[] arr : arrays) {
            length += arr.length;
        }
        byte[] ret = new byte[length];
        int offset = 0;
        for (byte[] arr : arrays) {
            System.arraycopy(arr, 0, ret, offset, arr.length);
            offset = arr.length;
        }
        return ret;
    }

    @Override
    public void clear() {
        for (BlockCipher c : ciphers) {
            c.reset();
        }
        ciphers.clear();
        for (KeyParameter pk : keys) {
            Arrays.fill(pk.getKey(), (byte) 00);
        }
        keys.clear();
    }

    @Override
    public Map<String, String> getParameters() {
        HashMap<String, String> map = new HashMap<>();
        map.put("N", Integer.toString(N));
        map.put("p", Integer.toString(p));
        map.put("r", Integer.toString(r));
        return map;
    }

}
