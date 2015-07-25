/*
 * Copyright © 2001,2012 by Paul Burlov. All Rights Reserved.
 * Created Jun 4, 2012
 */
package de.burlov.ultracipher.core.mail;

import java.util.Arrays;
import java.util.List;

import de.burlov.ultracipher.core.ICryptor;

public class GmxHandler extends MailHandler implements IMailHandler {

    @Override
    public void storeData(EmailCredentials creds, String data, ICryptor cryptor) throws Exception {
        sendData(new ServerParameters("mail.gmx.net", 465, creds.getEmailaddress(), creds.getPassword(), true), creds.getEmailaddress(),
                Arrays.asList(creds.getEmailaddress()), data, cryptor);
    }

    @Override
    public String retrieveData(EmailCredentials creds, boolean deleteSpam, ICryptor cryptor) throws Exception {
        // return retrieveDataPop3(new ServerParameters("pop.gmx.net", 995,
        // creds.getEmailaddress(), creds.getPassword(), true), deleteSpam);
        return retrieveDataIMAP(new ServerParameters("imap.gmx.net", 993, creds.getEmailaddress(), creds.getPassword(), true), cryptor);
    }

    @Override
    public List<SupportedDomain> getSupportedDomains() {
        return Arrays.asList(new SupportedDomain("gmx.de", ""), new SupportedDomain("gmx.net", ""));
    }
}
