/*
 * Copyright © 2001,2012 by Paul Burlov. All Rights Reserved.
 * Created Jun 3, 2012
 */
package de.burlov.ultracipher.core.mail;

import java.io.PrintWriter;
import java.util.List;

public interface IMailHandler {

    /**
     * @return Liste mit unterstuetzten Domains des Providers. Also das Teil der
     * Email-Adresse nach dem '@'
     */
    public List<SupportedDomain> getSupportedDomains();

    /**
     * Speichert Daten als Email an sich selbst
     *
     * @param creds
     * @param data
     * @throws java.io.IOException
     */
    public void storeData(EmailCredentials creds, String data) throws Exception;

    /**
     * Holt aktuellste Daten-Email ab
     *
     * @param creds
     * @return
     * @throws java.io.IOException
     */
    public String retrieveData(EmailCredentials creds, boolean deleteData) throws Exception;

    public void setDebugWriter(PrintWriter writer);
}
