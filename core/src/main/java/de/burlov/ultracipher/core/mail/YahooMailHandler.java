/*
 * Copyright © 2001,2012 by Paul Burlov. All Rights Reserved.
 * Created Jun 4, 2012
 */
package de.burlov.ultracipher.core.mail;

import java.io.IOException;
import java.util.Arrays;
import java.util.List;

import de.burlov.ultracipher.core.ICryptor;

public class YahooMailHandler extends MailHandler implements IMailHandler {

    @Override
    public void storeData(EmailCredentials creds, String data, ICryptor cryptor) throws Exception {
        sendData(new ServerParameters("smtp.mail.yahoo.com", 465, creds.getUserPart(), creds.getPassword(), true), creds.getEmailaddress(),
                Arrays.asList(creds.getEmailaddress()), data, cryptor);
    }

    @Override
    public String retrieveData(EmailCredentials creds, boolean deleteSpam, ICryptor cryptor) throws IOException {
        return retrieveDataPop3(new ServerParameters("pop.mail.yahoo.com", 995, creds.getUserPart(), creds.getPassword(), true), deleteSpam);
    }

    @Override
    public List<SupportedDomain> getSupportedDomains() {
        return Arrays.asList(new SupportedDomain("yahoo.com", ""), new SupportedDomain("yahoo.de", ""));
    }
}
