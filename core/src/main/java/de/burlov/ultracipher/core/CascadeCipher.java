/**
 Copyright (C) 2009 Paul Burlov
 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */
package de.burlov.ultracipher.core;

import java.util.List;

import de.burlov.ultracipher.core.bouncycastle.crypto.BlockCipher;
import de.burlov.ultracipher.core.bouncycastle.crypto.CipherParameters;
import de.burlov.ultracipher.core.bouncycastle.crypto.DataLengthException;


/**
 * Created 08.07.2009
 *
 * @author paul
 */
public class CascadeCipher implements BlockCipher {
    private int blockSize;
    private BlockCipher[] ciphers;
    private byte[] buf;

    public CascadeCipher(int blockSize, List<BlockCipher> ciphers) {
        this.blockSize = blockSize;
        this.buf = new byte[blockSize];
        this.ciphers = ciphers.toArray(new BlockCipher[ciphers.size()]);
        for (BlockCipher cipher : ciphers) {
            if (cipher.getBlockSize() != blockSize) {
                throw new IllegalArgumentException("Block size of cipher " + cipher.getAlgorithmName() + " " + cipher.getBlockSize() + " != " + blockSize);
            }
        }
    }

    /*
     * (non-Javadoc)
     *
     * @see org.bouncycastle.crypto.BlockCipher#getAlgorithmName()
     */
    @Override
    public String getAlgorithmName() {
        StringBuilder sb = new StringBuilder();
        for (BlockCipher c : ciphers) {
            if (sb.length() > 0) {
                sb.append('/');
            }
            sb.append(c.getAlgorithmName());
        }
        return sb.toString();
    }

    /*
     * (non-Javadoc)
     *
     * @see org.bouncycastle.crypto.BlockCipher#getBlockSize()
     */
    @Override
    public int getBlockSize() {
        return blockSize;
    }

    /*
     * (non-Javadoc)
     *
     * @see org.bouncycastle.crypto.BlockCipher#init(boolean,
     * org.bouncycastle.crypto.CipherParameters)
     */
    @Override
    public void init(boolean forEncryption, CipherParameters params) throws IllegalArgumentException {
        // ignore
    }

    /*
     * (non-Javadoc)
     *
     * @see org.bouncycastle.crypto.BlockCipher#processBlock(byte[], int,
     * byte[], int)
     */
    @Override
    public int processBlock(byte[] in, int inOff, byte[] out, int outOff) throws DataLengthException, IllegalStateException {
        int ret = 0;
        /*
         * Input in ein Zwischenbuffer kopieren
		 */
        System.arraycopy(in, inOff, buf, 0, blockSize);
        for (BlockCipher c : ciphers) {
            ret = c.processBlock(buf, 0, out, outOff);
			/*
			 * Jetzt Resultat wieder in Zwischenbuffer als Input fuer naechste
			 * Iteration kopieren
			 */
            System.arraycopy(out, outOff, buf, 0, blockSize);
        }
        return ret;
    }

    /*
     * (non-Javadoc)
     *
     * @see org.bouncycastle.crypto.BlockCipher#reset()
     */
    @Override
    public void reset() {
        for (BlockCipher c : ciphers) {
            c.reset();
        }
    }

}
