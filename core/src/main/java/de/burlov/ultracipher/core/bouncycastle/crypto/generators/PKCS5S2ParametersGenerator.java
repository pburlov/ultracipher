package de.burlov.ultracipher.core.bouncycastle.crypto.generators;

import de.burlov.ultracipher.core.bouncycastle.crypto.CipherParameters;
import de.burlov.ultracipher.core.bouncycastle.crypto.Digest;
import de.burlov.ultracipher.core.bouncycastle.crypto.Mac;
import de.burlov.ultracipher.core.bouncycastle.crypto.PBEParametersGenerator;
import de.burlov.ultracipher.core.bouncycastle.crypto.digests.SHA1Digest;
import de.burlov.ultracipher.core.bouncycastle.crypto.macs.HMac;
import de.burlov.ultracipher.core.bouncycastle.crypto.params.KeyParameter;
import de.burlov.ultracipher.core.bouncycastle.crypto.params.ParametersWithIV;

/**
 * Generator for PBE derived keys and ivs as defined by PKCS 5 V2.0 Scheme 2.
 * This generator uses a SHA-1 HMac as the calculation function.
 * <p/>
 * The document this implementation is based on can be found at
 * <a href=http://www.rsasecurity.com/rsalabs/pkcs/pkcs-5/index.html>
 * RSA's PKCS5 Page</a>
 */
public class PKCS5S2ParametersGenerator
        extends PBEParametersGenerator {
    private Mac hMac;

    /**
     * construct a PKCS5 Scheme 2 Parameters generator.
     */
    public PKCS5S2ParametersGenerator() {
        this(new SHA1Digest());
    }

    public PKCS5S2ParametersGenerator(Digest digest) {
        hMac = new HMac(digest);
    }

    private void F(
            byte[] P,
            byte[] S,
            int c,
            byte[] iBuf,
            byte[] out,
            int outOff) {
        byte[] state = new byte[hMac.getMacSize()];
        CipherParameters param = new KeyParameter(P);

        hMac.init(param);

        if (S != null) {
            hMac.update(S, 0, S.length);
        }

        hMac.update(iBuf, 0, iBuf.length);

        hMac.doFinal(state, 0);

        System.arraycopy(state, 0, out, outOff, state.length);

        if (c == 0) {
            throw new IllegalArgumentException("iteration count must be at least 1.");
        }

        for (int count = 1; count < c; count++) {
            hMac.init(param);
            hMac.update(state, 0, state.length);
            hMac.doFinal(state, 0);

            for (int j = 0; j != state.length; j++) {
                out[outOff + j] ^= state[j];
            }
        }
    }

    private void intToOctet(
            byte[] buf,
            int i) {
        buf[0] = (byte) (i >>> 24);
        buf[1] = (byte) (i >>> 16);
        buf[2] = (byte) (i >>> 8);
        buf[3] = (byte) i;
    }

    private byte[] generateDerivedKey(
            int dkLen) {
        int hLen = hMac.getMacSize();
        int l = (dkLen + hLen - 1) / hLen;
        byte[] iBuf = new byte[4];
        byte[] out = new byte[l * hLen];

        for (int i = 1; i <= l; i++) {
            intToOctet(iBuf, i);

            F(password, salt, iterationCount, iBuf, out, (i - 1) * hLen);
        }

        return out;
    }

    /**
     * Generate a key parameter derived from the password, salt, and iteration
     * count we are currently initialised with.
     *
     * @param keySize the size of the key we want (in bits)
     * @return a KeyParameter object.
     */
    public CipherParameters generateDerivedParameters(
            int keySize) {
        keySize = keySize / 8;

        byte[] dKey = generateDerivedKey(keySize);

        return new KeyParameter(dKey, 0, keySize);
    }

    /**
     * Generate a key with initialisation vector parameter derived from
     * the password, salt, and iteration count we are currently initialised
     * with.
     *
     * @param keySize the size of the key we want (in bits)
     * @param ivSize  the size of the iv we want (in bits)
     * @return a ParametersWithIV object.
     */
    public CipherParameters generateDerivedParameters(
            int keySize,
            int ivSize) {
        keySize = keySize / 8;
        ivSize = ivSize / 8;

        byte[] dKey = generateDerivedKey(keySize + ivSize);

        return new ParametersWithIV(new KeyParameter(dKey, 0, keySize), dKey, keySize, ivSize);
    }

    /**
     * Generate a key parameter for use with a MAC derived from the password,
     * salt, and iteration count we are currently initialised with.
     *
     * @param keySize the size of the key we want (in bits)
     * @return a KeyParameter object.
     */
    public CipherParameters generateDerivedMacParameters(
            int keySize) {
        return generateDerivedParameters(keySize);
    }
}