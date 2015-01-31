/*
 * Copyright © 2001,2012 by Paul Burlov. All Rights Reserved.
 * Created Jun 27, 2012
 */
package de.burlov.ultracipher.core.mail;

import org.apache.commons.lang3.StringUtils;

public class SupportedDomain {

    public final String domain;
    public final String comment;

    SupportedDomain(String domain, String comment) {
        super();
        this.domain = domain;
        this.comment = comment;
    }

    public boolean matches(String address) {
        return StringUtils.trimToEmpty(address).toLowerCase().endsWith(domain.toLowerCase());
    }

    @Override
    public String toString() {
        return domain;
    }
}
