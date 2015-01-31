package de.burlov.ultracipher.core.bouncycastle.crypto.modes.gcm;

public interface GCMMultiplier {
    void init(byte[] H);

    void multiplyH(byte[] x);
}
