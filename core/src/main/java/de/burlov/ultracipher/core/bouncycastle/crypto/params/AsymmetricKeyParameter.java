package de.burlov.ultracipher.core.bouncycastle.crypto.params;

import de.burlov.ultracipher.core.bouncycastle.crypto.CipherParameters;

public class AsymmetricKeyParameter
        implements CipherParameters {
    boolean privateKey;

    public AsymmetricKeyParameter(
            boolean privateKey) {
        this.privateKey = privateKey;
    }

    public boolean isPrivate() {
        return privateKey;
    }
}
