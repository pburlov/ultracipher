package de.burlov.ultracipher.core.bouncycastle.util;

import java.util.Collection;

public interface Store {
    Collection getMatches(Selector selector)
            throws StoreException;
}
