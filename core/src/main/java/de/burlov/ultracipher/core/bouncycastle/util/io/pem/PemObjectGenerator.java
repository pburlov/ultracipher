package de.burlov.ultracipher.core.bouncycastle.util.io.pem;

public interface PemObjectGenerator {
    PemObject generate()
            throws PemGenerationException;
}
