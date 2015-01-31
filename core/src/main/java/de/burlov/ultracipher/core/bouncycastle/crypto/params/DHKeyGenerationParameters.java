package de.burlov.ultracipher.core.bouncycastle.crypto.params;

import java.security.SecureRandom;

import de.burlov.ultracipher.core.bouncycastle.crypto.KeyGenerationParameters;


public class DHKeyGenerationParameters
        extends KeyGenerationParameters {
    private DHParameters params;

    public DHKeyGenerationParameters(
            SecureRandom random,
            DHParameters params) {
        super(random, getStrength(params));

        this.params = params;
    }

    static int getStrength(DHParameters params) {
        return params.getL() != 0 ? params.getL() : params.getP().bitLength();
    }

    public DHParameters getParameters() {
        return params;
    }
}
