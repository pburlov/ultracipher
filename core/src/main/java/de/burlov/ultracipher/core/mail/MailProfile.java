/*
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
package de.burlov.ultracipher.core.mail;

/**
 * Created 26.03.2009
 *
 * @author paul
 */
abstract public class MailProfile {
    private ServerParameters pop3Params;
    private ServerParameters smtpParams;
    private boolean deleteUnknownMessages = false;
    /*
     * Emailadressen wohin die Kopien beim Speichern als CC geschickt werden.
     */
    private String backupAdresses = "";

    public ServerParameters getPop3Params() {
        return pop3Params;
    }

    public void setPop3Params(ServerParameters pop3Params) {
        this.pop3Params = pop3Params;
    }

    public ServerParameters getSmtpParams() {
        return smtpParams;
    }

    public void setSmtpParams(ServerParameters smtpParams) {
        this.smtpParams = smtpParams;
    }

    public boolean isDeleteUnknownMessages() {
        return deleteUnknownMessages;
    }

    public void setDeleteUnknownMessages(boolean deleteUnknownMessages) {
        this.deleteUnknownMessages = deleteUnknownMessages;
    }

    public String getBackupAdresses() {
        return backupAdresses;
    }

    public void setBackupAdresses(String backupAdresses) {
        this.backupAdresses = backupAdresses;
    }

}
