package de.burlov.ultracipher.core.bouncycastle.crypto.generators;


import java.math.BigInteger;

import de.burlov.ultracipher.core.bouncycastle.crypto.AsymmetricCipherKeyPair;
import de.burlov.ultracipher.core.bouncycastle.crypto.AsymmetricCipherKeyPairGenerator;
import de.burlov.ultracipher.core.bouncycastle.crypto.KeyGenerationParameters;
import de.burlov.ultracipher.core.bouncycastle.crypto.params.DHKeyGenerationParameters;
import de.burlov.ultracipher.core.bouncycastle.crypto.params.DHParameters;
import de.burlov.ultracipher.core.bouncycastle.crypto.params.DHPrivateKeyParameters;
import de.burlov.ultracipher.core.bouncycastle.crypto.params.DHPublicKeyParameters;

/**
 * a Diffie-Hellman key pair generator.
 * <p/>
 * This generates keys consistent for use in the MTI/A0 key agreement protocol
 * as described in "Handbook of Applied Cryptography", Pages 516-519.
 */
public class DHKeyPairGenerator
        implements AsymmetricCipherKeyPairGenerator {
    private DHKeyGenerationParameters param;

    public void init(
            KeyGenerationParameters param) {
        this.param = (DHKeyGenerationParameters) param;
    }

    public AsymmetricCipherKeyPair generateKeyPair() {
        DHKeyGeneratorHelper helper = DHKeyGeneratorHelper.INSTANCE;
        DHParameters dhp = param.getParameters();

        BigInteger x = helper.calculatePrivate(dhp, param.getRandom());
        BigInteger y = helper.calculatePublic(dhp, x);

        return new AsymmetricCipherKeyPair(
                new DHPublicKeyParameters(y, dhp),
                new DHPrivateKeyParameters(x, dhp));
    }
}
