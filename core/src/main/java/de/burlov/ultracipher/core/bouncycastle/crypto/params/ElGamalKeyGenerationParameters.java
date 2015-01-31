package de.burlov.ultracipher.core.bouncycastle.crypto.params;

import java.security.SecureRandom;

import de.burlov.ultracipher.core.bouncycastle.crypto.KeyGenerationParameters;


public class ElGamalKeyGenerationParameters
        extends KeyGenerationParameters {
    private ElGamalParameters params;

    public ElGamalKeyGenerationParameters(
            SecureRandom random,
            ElGamalParameters params) {
        super(random, getStrength(params));

        this.params = params;
    }

    static int getStrength(ElGamalParameters params) {
        return params.getL() != 0 ? params.getL() : params.getP().bitLength();
    }

    public ElGamalParameters getParameters() {
        return params;
    }
}
