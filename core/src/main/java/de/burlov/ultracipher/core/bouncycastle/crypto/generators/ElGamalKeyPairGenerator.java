package de.burlov.ultracipher.core.bouncycastle.crypto.generators;

import java.math.BigInteger;

import de.burlov.ultracipher.core.bouncycastle.crypto.AsymmetricCipherKeyPair;
import de.burlov.ultracipher.core.bouncycastle.crypto.AsymmetricCipherKeyPairGenerator;
import de.burlov.ultracipher.core.bouncycastle.crypto.KeyGenerationParameters;
import de.burlov.ultracipher.core.bouncycastle.crypto.params.DHParameters;
import de.burlov.ultracipher.core.bouncycastle.crypto.params.ElGamalKeyGenerationParameters;
import de.burlov.ultracipher.core.bouncycastle.crypto.params.ElGamalParameters;
import de.burlov.ultracipher.core.bouncycastle.crypto.params.ElGamalPrivateKeyParameters;
import de.burlov.ultracipher.core.bouncycastle.crypto.params.ElGamalPublicKeyParameters;


/**
 * a ElGamal key pair generator.
 * <p/>
 * This generates keys consistent for use with ElGamal as described in
 * page 164 of "Handbook of Applied Cryptography".
 */
public class ElGamalKeyPairGenerator
        implements AsymmetricCipherKeyPairGenerator {
    private ElGamalKeyGenerationParameters param;

    public void init(
            KeyGenerationParameters param) {
        this.param = (ElGamalKeyGenerationParameters) param;
    }

    public AsymmetricCipherKeyPair generateKeyPair() {
        DHKeyGeneratorHelper helper = DHKeyGeneratorHelper.INSTANCE;
        ElGamalParameters egp = param.getParameters();
        DHParameters dhp = new DHParameters(egp.getP(), egp.getG(), null, egp.getL());

        BigInteger x = helper.calculatePrivate(dhp, param.getRandom());
        BigInteger y = helper.calculatePublic(dhp, x);

        return new AsymmetricCipherKeyPair(
                new ElGamalPublicKeyParameters(y, egp),
                new ElGamalPrivateKeyParameters(x, egp));
    }
}
