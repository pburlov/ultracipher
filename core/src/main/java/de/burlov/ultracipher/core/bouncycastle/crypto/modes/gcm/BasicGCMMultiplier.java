package de.burlov.ultracipher.core.bouncycastle.crypto.modes.gcm;

import de.burlov.ultracipher.core.bouncycastle.util.Arrays;

public class BasicGCMMultiplier implements GCMMultiplier {
    private byte[] H;

    public void init(byte[] H) {
        this.H = Arrays.clone(H);
    }

    public void multiplyH(byte[] x) {
        GCMUtil.multiply(x, H);
    }
}
