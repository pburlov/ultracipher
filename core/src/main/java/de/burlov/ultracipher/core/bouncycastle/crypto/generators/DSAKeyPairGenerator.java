package de.burlov.ultracipher.core.bouncycastle.crypto.generators;


import java.math.BigInteger;
import java.security.SecureRandom;

import de.burlov.ultracipher.core.bouncycastle.crypto.AsymmetricCipherKeyPair;
import de.burlov.ultracipher.core.bouncycastle.crypto.AsymmetricCipherKeyPairGenerator;
import de.burlov.ultracipher.core.bouncycastle.crypto.KeyGenerationParameters;
import de.burlov.ultracipher.core.bouncycastle.crypto.params.DSAKeyGenerationParameters;
import de.burlov.ultracipher.core.bouncycastle.crypto.params.DSAParameters;
import de.burlov.ultracipher.core.bouncycastle.crypto.params.DSAPrivateKeyParameters;
import de.burlov.ultracipher.core.bouncycastle.crypto.params.DSAPublicKeyParameters;
import de.burlov.ultracipher.core.bouncycastle.util.BigIntegers;

/**
 * a DSA key pair generator.
 * <p/>
 * This generates DSA keys in line with the method described
 * in <i>FIPS 186-3 B.1 FFC Key Pair Generation</i>.
 */
public class DSAKeyPairGenerator
        implements AsymmetricCipherKeyPairGenerator {
    private static final BigInteger ONE = BigInteger.valueOf(1);

    private DSAKeyGenerationParameters param;

    private static BigInteger generatePrivateKey(BigInteger q, SecureRandom random) {
        // TODO Prefer this method? (change test cases that used fixed random)
        // B.1.1 Key Pair Generation Using Extra Random Bits
//        BigInteger c = new BigInteger(q.bitLength() + 64, random);
//        return c.mod(q.subtract(ONE)).add(ONE);

        // B.1.2 Key Pair Generation by Testing Candidates
        return BigIntegers.createRandomInRange(ONE, q.subtract(ONE), random);
    }

    private static BigInteger calculatePublicKey(BigInteger p, BigInteger g, BigInteger x) {
        return g.modPow(x, p);
    }

    public void init(
            KeyGenerationParameters param) {
        this.param = (DSAKeyGenerationParameters) param;
    }

    public AsymmetricCipherKeyPair generateKeyPair() {
        DSAParameters dsaParams = param.getParameters();

        BigInteger x = generatePrivateKey(dsaParams.getQ(), param.getRandom());
        BigInteger y = calculatePublicKey(dsaParams.getP(), dsaParams.getG(), x);

        return new AsymmetricCipherKeyPair(
                new DSAPublicKeyParameters(y, dsaParams),
                new DSAPrivateKeyParameters(x, dsaParams));
    }
}
