/*
 * Copyright © 2001,2012 by Paul Burlov. All Rights Reserved.
 * Created Jun 3, 2012
 */
package de.burlov.ultracipher.core.mail;

import org.apache.commons.lang3.StringUtils;

import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * High Level API fuer Email-Backend
 *
 * @author paul
 */
public class EmailStore {
    private List<IMailHandler> handlers = Arrays.asList((IMailHandler) new GoogleMailHandler() /*,new MailRuHandler()*/, new GmxHandler());
    private PrintWriter log;

    public EmailStore(PrintWriter log) {
        super();
        this.log = log;
    }

    /**
     * Liefert Liste mit Domains der Email-Anbieter. Also Teil des Email-Adresses
     * nach dem @-Zeichen
     *
     * @return
     */
    public List<SupportedDomain> getSupportedMailDomains() {
        ArrayList<SupportedDomain> ret = new ArrayList<SupportedDomain>();
        for (IMailHandler handler : handlers) {
            ret.addAll(handler.getSupportedDomains());
        }
        return ret;
    }

    /**
     * Laedt Data von einem Email-Account
     *
     * @param credentials Anmeldedaten
     * @return
     * @throws Exception
     */
    public String loadData(EmailCredentials credentials, boolean deleteSpam) throws Exception {
        IMailHandler handler = findResponsibleHandler(credentials.getEmailaddress());
        if (handler == null) {
            throw new Exception("not supported domain: " + credentials.getDomainPart());
        }
        handler.setDebugWriter(log);
        return handler.retrieveData(credentials, deleteSpam);
    }

    public void saveData(EmailCredentials credentials, String data) throws Exception {
        IMailHandler handler = findResponsibleHandler(credentials.getEmailaddress());
        if (handler == null) {
            throw new Exception("not supported domain: " + credentials.getDomainPart());
        }
        handler.setDebugWriter(log);
        handler.storeData(credentials, data);
    }

    /**
     * findet MailHandler der fuer die angegebene Email-Adresse zustaendig ist
     *
     * @param emailAddress
     * @return
     */
    private IMailHandler findResponsibleHandler(String emailAddress) {
        for (IMailHandler handler : handlers) {
            for (SupportedDomain domain : handler.getSupportedDomains()) {
                if (StringUtils.endsWith(emailAddress, domain.domain)) {
                    return handler;
                }
            }
        }
        return null;
    }
}
