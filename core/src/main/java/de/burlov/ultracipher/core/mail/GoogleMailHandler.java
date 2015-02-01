/*
 * Copyright © 2001,2012 by Paul Burlov. All Rights Reserved.
 * Created Jun 3, 2012
 */
package de.burlov.ultracipher.core.mail;

import java.util.Arrays;
import java.util.List;

/**
 * Bei Gmail werden per POP3 aufgerufen Nachrichten nur 30 Tage lang zum
 * wiedeholten Abruf gehalten
 * <p/>
 * http://mail.google.com/support/bin/answer.py?answer=47948&query=recent&topic=
 * &type=f&ctx=search
 *
 * @author paul
 */
public class GoogleMailHandler extends MailHandler implements IMailHandler {

    @Override
    public void storeData(EmailCredentials creds, String data) throws Exception {
        sendData(new ServerParameters("smtp.googlemail.com", 465, creds.getEmailaddress(), creds.getPassword(), true), creds.getEmailaddress(),
                Arrays.asList(creds.getEmailaddress()), data);
    }

    @Override
    public String retrieveData(EmailCredentials creds, boolean deleteSpam) throws Exception {
        return retrieveDataIMAP(new ServerParameters("imap.googlemail.com", 993, creds.getEmailaddress(), creds.getPassword(), true));
    }

    @Override
    public List<SupportedDomain> getSupportedDomains() {
        String comment = "Please enable IMAP access in your GMail settings";
        return Arrays.asList(new SupportedDomain("gmail.com", comment), new SupportedDomain("googlemail.com", comment));
    }

}
