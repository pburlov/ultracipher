/*
 * Copyright © 2017 by Paul Burlov. All Rights Reserved.
 * Created April 1 2017
 */
package de.burlov.ultracipher.core.mail;

import java.util.Arrays;
import java.util.List;

import de.burlov.ultracipher.core.ICryptor;

public class EinsUndEinsHandler extends MailHandler implements IMailHandler {

    @Override
    public void storeData(EmailCredentials creds, String data, ICryptor cryptor) throws Exception {
        sendData(new ServerParameters("smtp.1und1.de", 587, creds.getEmailaddress(), creds.getPassword(), false), creds.getEmailaddress(),
                Arrays.asList(creds.getEmailaddress()), data, cryptor);
    }

    @Override
    public String retrieveData(EmailCredentials creds, boolean deleteSpam, ICryptor cryptor) throws Exception {
        return retrieveDataIMAP(new ServerParameters("imap.1und1.de", 993, creds.getEmailaddress(), creds.getPassword(), true), cryptor);
    }

    @Override
    public List<SupportedDomain> getSupportedDomains() {
        return Arrays.asList(new SupportedDomain("burlov.de", ""),new SupportedDomain("ultracipher.de", ""));
    }
}
